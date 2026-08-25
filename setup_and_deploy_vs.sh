#!/usr/bin/env bash
#
# SONiC Virtual Switch (VS) — Full Setup & Deployment Script
#
# This script:
#   1. Installs all host dependencies (Docker, compose plugin, Python tools)
#   2. Clones sonic-buildimage (VS branch) if not already present
#   3. Builds VS docker images OR loads from pre-built .gz archives
#   4. Creates deployment directory structure and config files
#   5. Deploys the VS device via docker-compose
#   6. Loads configuration into CONFIG_DB (Redis)
#
# Usage:
#   bash setup_and_deploy_vs.sh              # Full setup + deploy
#   bash setup_and_deploy_vs.sh --deps-only  # Install dependencies only
#   bash setup_and_deploy_vs.sh --build-only # Build images only (after deps)
#   bash setup_and_deploy_vs.sh --deploy-only # Deploy only (images must exist)
#   bash setup_and_deploy_vs.sh --stop       # Stop all containers
#   bash setup_and_deploy_vs.sh --cleanup    # Stop containers + remove networks
#   bash setup_and_deploy_vs.sh --status     # Show status
#   bash setup_and_deploy_vs.sh --logs       # Follow logs
#
set -euo pipefail

###############################################################################
# Configuration
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}"
DEPLOY_DIR="${PROJECT_DIR}/deployment"
CONFIG_DIR="${DEPLOY_DIR}/config"
HWSKU_DIR="${DEPLOY_DIR}/hwsku"
LOG_DIR="${DEPLOY_DIR}/logs"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"

# Build image source
BUILD_REPO="https://github.com/sonic-net/sonic-buildimage.git"
BUILD_BRANCH="${SONIC_BRANCH:-master}"
BUILD_DIR="${PROJECT_DIR}/sonic-buildimage"
TARGET_DIR="${PROJECT_DIR}/sonic-extracted/sonic-buildimage.vs/target"

# Build settings (override via environment)
PLATFORM="${PLATFORM:-vs}"
BUILD_SKIP_TEST="${BUILD_SKIP_TEST:-y}"

# Auto-detect build jobs and memory based on host resources.
# Rule of thumb (per sonic-buildimage README):
#   RAM needed ≈ (JOBS × 6 GB) + 4 GB
#   Disk needed ≈ 100 GB base + extra for parallelism
# Users can always override with SONIC_BUILD_JOBS=N.
detect_build_resources() {
    # --- CPU detection ---
    local cpus
    if command -v nproc &>/dev/null; then
        cpus=$(nproc)
    elif [ -r /proc/cpuinfo ]; then
        cpus=$(grep -c ^processor /proc/cpuinfo)
    else
        cpus=2
    fi

    # --- RAM detection (in GB, integer) ---
    local ram_gb=0
    if [ -r /proc/meminfo ]; then
        local ram_kb
        ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        ram_gb=$(( ram_kb / 1024 / 1024 ))
    fi

    # --- Disk detection (free GB on project dir filesystem) ---
    local disk_gb=0
    if command -v df &>/dev/null; then
        disk_gb=$(df -BG "${PROJECT_DIR}" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}')
        disk_gb=${disk_gb:-0}
    fi

    # --- Resolve JOBS ---
    # Formula: min(CPUs, floor((RAM - 4) / 6), floor(DISK / 30))
    #   - 6 GB per parallel C++ compile job
    #   - 4 GB base overhead (docker, kernel, etc.)
    #   - 30 GB per job for build artifacts
    local jobs_by_cpu=$cpus
    local jobs_by_ram=$(( (ram_gb - 4) / 6 ))
    local jobs_by_disk=$(( disk_gb / 30 ))
    [ "$jobs_by_ram" -lt 1 ] && jobs_by_ram=1
    [ "$jobs_by_disk" -lt 1 ] && jobs_by_disk=1

    local auto_jobs
    auto_jobs=$(( jobs_by_cpu < jobs_by_ram ? jobs_by_cpu : jobs_by_ram ))
    auto_jobs=$(( auto_jobs < jobs_by_disk ? auto_jobs : jobs_by_disk ))
    [ "$auto_jobs" -lt 1 ] && auto_jobs=1

    # Cap at 16 to avoid pathological cases
    [ "$auto_jobs" -gt 16 ] && auto_jobs=16

    # --- Resolve MEMORY (for SONIC_BUILD_MEMORY in rules/config.user) ---
    # Reserve 4 GB for host, give the rest to the build container, cap at 24 GB.
    local build_mem_gb=$(( ram_gb - 4 ))
    [ "$build_mem_gb" -lt 8 ] && build_mem_gb=8
    [ "$build_mem_gb" -gt 24 ] && build_mem_gb=24

    # Export so functions downstream can read them
    DETECTED_CPUS=$cpus
    DETECTED_RAM_GB=$ram_gb
    DETECTED_DISK_GB=$disk_gb
    DETECTED_BUILD_MEMORY="${build_mem_gb}g"

    # Honor explicit user override
    if [ -n "${SONIC_BUILD_JOBS:-}" ]; then
        log_info "Build jobs: ${SONIC_BUILD_JOBS} (user override)"
    else
        SONIC_BUILD_JOBS=$auto_jobs
        log_info "Build jobs: ${SONIC_BUILD_JOBS} (auto: ${cpus} CPU / ${ram_gb}G RAM / ${disk_gb}G disk)"
    fi

    if [ -n "${SONIC_BUILD_MEMORY:-}" ]; then
        log_info "Build memory: ${SONIC_BUILD_MEMORY} (user override)"
        DETECTED_BUILD_MEMORY="${SONIC_BUILD_MEMORY}"
    else
        log_info "Build memory: ${DETECTED_BUILD_MEMORY} (auto: ${ram_gb}G RAM detected)"
    fi
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

###############################################################################
# Logging helpers
###############################################################################
log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${BLUE}[STEP]${NC} $1"; }
log_success() { echo -e "${GREEN}[DONE]${NC} $1"; }

dashboard_header() {
    echo ""
    echo "============================================================"
    echo " SONiC VS SETUP DASHBOARD"
    echo "============================================================"
}

dashboard_bar() {
    local label="$1"
    local current="$2"
    local total="$3"
    local width=24
    local filled=0
    [ "$total" -gt 0 ] && filled=$((current * width / total))
    [ "$filled" -gt "$width" ] && filled=$width
    local empty=$((width - filled))
    printf "%-22s [" "$label"
    printf '%*s' "$filled" '' | tr ' ' '#'
    printf '%*s' "$empty" '' | tr ' ' '-'
    printf "] %s/%s\n" "$current" "$total"
}

show_dashboard() {
    dashboard_header
    printf " Host: %-45s\n" "$(hostname 2>/dev/null || echo unknown)"
    printf " Time: %-45s\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""

    if [ -n "${DETECTED_CPUS:-}" ]; then
        echo "Build resources"
        printf "  CPUs: %-8s RAM: %-8s Free disk: %s\n" \
            "${DETECTED_CPUS}" "${DETECTED_RAM_GB} GB" "${DETECTED_DISK_GB} GB"
        printf "  Jobs: %-8s Memory limit: %s\n" \
            "${SONIC_BUILD_JOBS}" "${DETECTED_BUILD_MEMORY}"
        echo ""
    fi

    echo "Required images"
    local images=(
        "docker-gbsyncd-vs:latest"
        "docker-database:latest"
        "docker-orchagent:latest"
        "docker-eventd:latest"
        "docker-lldp:latest"
    )
    local present=0
    local image
    for image in "${images[@]}"; do
        if command -v docker &>/dev/null && docker image inspect "$image" &>/dev/null; then
            printf "  [OK]   %s\n" "$image"
            present=$((present + 1))
        else
            printf "  [TODO] %s\n" "$image"
        fi
    done
    dashboard_bar "Images" "$present" "${#images[@]}"
    echo ""

    echo "Deployment"
    if command -v docker &>/dev/null && docker compose -f "${COMPOSE_FILE}" ps --status running -q 2>/dev/null | grep -q .; then
        local running
        running=$(docker compose -f "${COMPOSE_FILE}" ps --status running -q 2>/dev/null | wc -l)
        dashboard_bar "Containers running" "$running" 5
    else
        dashboard_bar "Containers running" 0 5
    fi
    if command -v docker &>/dev/null && docker exec sonic-database redis-cli ping &>/dev/null; then
        echo "  Redis:              READY"
    else
        echo "  Redis:              TODO (start database container)"
    fi
    if ip link show sonic-vs-br &>/dev/null 2>&1; then
        echo "  VS bridge:          READY"
    else
        echo "  VS bridge:          TODO (run deploy)"
    fi
    echo ""

    echo "Next actions"
    if [ "$present" -lt "${#images[@]}" ]; then
        echo "  1. Load the missing image archives or build from source"
    elif ! command -v docker &>/dev/null || ! docker compose -f "${COMPOSE_FILE}" ps --status running -q 2>/dev/null | grep -q .; then
        echo "  1. Run: sudo bash $0 --deploy-only"
    else
        echo "  1. Check service health and CONFIG_DB"
        echo "  2. Run: bash $0 --logs"
    fi
    echo "============================================================"
}

###############################################################################
# Dependency checks & installation
###############################################################################
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script requires root/sudo privileges for installing dependencies."
        log_error "Please run with: sudo bash $0"
        exit 1
    fi
}

check_os() {
    log_step "Detecting OS..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        log_info "OS: ${OS_ID} ${OS_VERSION}"
    else
        log_error "Cannot detect OS. Install dependencies manually."
        exit 1
    fi

    case "${OS_ID}" in
        ubuntu|debian) ;;
        *) log_warn "Unsupported OS: ${OS_ID}. Proceeding but packages may differ." ;;
    esac
}

install_packages() {
    log_step "Installing system packages..."

    if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq

        # Core build tools
        apt-get install -y -qq \
            git curl wget unzip \
            python3 python3-pip python3-venv \
            iproute2 iputils-ping \
            kmod \
            2>/dev/null || true

    elif [[ "${OS_ID}" == "centos" || "${OS_ID}" == "rhel" || "${OS_ID}" == "fedora" ]]; then
        yum install -y \
            git curl wget unzip \
            python3 python3-pip \
            iproute iputils \
            kernel-modules \
            2>/dev/null || true
    else
        log_warn "Unknown package manager — skipping system packages."
    fi
}

install_python_tools() {
    log_step "Installing Python tools (jinjanator)..."
    pip3 install --user --quiet jinjanator 2>/dev/null || \
        pip3 install --quiet jinjanator 2>/dev/null || \
        log_warn "Could not install jinjanator via pip3"

    # Verify j2 command works
    if command -v j2 &>/dev/null || command -v ~/.local/bin/j2 &>/dev/null; then
        log_success "j2/jinjanator installed"
    else
        log_warn "j2 command not found in PATH — may need to add ~/.local/bin to PATH"
    fi
}

install_docker() {
    log_step "Checking Docker installation..."

    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        log_info "Docker is already installed: $(docker --version)"

        # Check compose plugin
        if docker compose version &>/dev/null 2>&1; then
            log_info "Docker Compose plugin: $(docker compose version --short 2>/dev/null)"
        else
            log_warn "Docker Compose plugin not found. Installing..."
            install_docker_compose_plugin
        fi
        return 0
    fi

    log_info "Docker not found. Installing..."

    if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "debian" ]]; then
        # Remove any snap-installed Docker first
        if command -v snap &>/dev/null; then
            snap remove docker 2>/dev/null || true
        fi

        # Remove old versions
        for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
            apt-get remove -y -qq "$pkg" 2>/dev/null || true
        done

        # Add Docker's official GPG key and repo
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg \
            -o /etc/apt/keyrings/docker.asc 2>/dev/null || true
        chmod a+r /etc/apt/keyrings/docker.asc

        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
            https://download.docker.com/linux/${OS_ID} \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin 2>/dev/null || {
            log_warn "Official Docker repo failed. Trying distro packages..."
            apt-get install -y -qq docker.io 2>/dev/null || true
        }

        # Start and enable Docker
        systemctl start docker 2>/dev/null || true
        systemctl enable docker 2>/dev/null || true

    elif [[ "${OS_ID}" == "centos" || "${OS_ID}" == "rhel" || "${OS_ID}" == "fedora" ]]; then
        yum install -y yum-utils 2>/dev/null || true
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
        yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin 2>/dev/null || true
        systemctl start docker 2>/dev/null || true
        systemctl enable docker 2>/dev/null || true
    fi

    # Install compose plugin if not present
    install_docker_compose_plugin

    # Add current user to docker group
    local current_user="${SUDO_USER:-$(whoami)}"
    if [ -n "$current_user" ] && [ "$current_user" != "root" ]; then
        groupadd -f docker 2>/dev/null || true
        usermod -aG docker "$current_user" 2>/dev/null || true
        log_info "Added user '$current_user' to docker group (log out/in to apply)"
    fi

    # Load overlay module
    modprobe overlay 2>/dev/null || true

    if docker info &>/dev/null 2>&1; then
        log_success "Docker installed and running: $(docker --version)"
    else
        log_error "Docker installation failed or daemon not running"
        exit 1
    fi
}

install_docker_compose_plugin() {
    if docker compose version &>/dev/null 2>&1; then
        return 0
    fi

    log_info "Installing Docker Compose plugin..."
    local compose_ver
    compose_ver=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
        | grep '"tag_name"' | head -1 | sed 's/.*"v\(.*\)".*/\1/' 2>/dev/null) || \
        compose_ver="2.29.1"

    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL "https://github.com/docker/compose/releases/download/v${compose_ver}/docker-compose-linux-x86_64" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose 2>/dev/null || {
        log_warn "Failed to download compose plugin v${compose_ver}, trying latest..."
        curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
            -o /usr/local/lib/docker/cli-plugins/docker-compose 2>/dev/null || true
    }
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose 2>/dev/null || true

    if docker compose version &>/dev/null 2>&1; then
        log_success "Docker Compose plugin installed"
    else
        log_warn "Docker Compose plugin installation may have failed"
    fi
}

###############################################################################
# Build image acquisition (clone + build OR load from archive)
###############################################################################
clone_build_repo() {
    log_step "Setting up sonic-buildimage repository..."

    if [ -d "${BUILD_DIR}/.git" ]; then
        log_info "Repository already cloned at ${BUILD_DIR}"
        cd "$BUILD_DIR"
        git fetch --all 2>/dev/null || true
        git checkout "$BUILD_BRANCH" 2>/dev/null || true
        git pull origin "$BUILD_BRANCH" 2>/dev/null || true
        git submodule update --init --recursive 2>/dev/null || true
        log_info "Repository updated"
        return 0
    fi

    log_info "Cloning sonic-buildimage (branch: ${BUILD_BRANCH})..."
    git clone --recurse-submodules -b "$BUILD_BRANCH" "$BUILD_REPO" "$BUILD_DIR"
    log_success "Repository cloned"
}

build_vs_images() {
    log_step "Building SONiC VS images..."

    # Auto-tune jobs and memory for this host (idempotent, env overrides win)
    detect_build_resources

    log_info "Platform: ${PLATFORM}"
    log_info "Build jobs: ${SONIC_BUILD_JOBS}"
    log_info "Build memory: ${DETECTED_BUILD_MEMORY}"
    log_info "Skip tests: ${BUILD_SKIP_TEST}"
    log_info "Build dir: ${BUILD_DIR}"

    # Persist memory limit so the build container doesn't OOM the host
    if [ -d "${BUILD_DIR}" ]; then
        mkdir -p "${BUILD_DIR}/rules"
        if ! grep -q '^SONIC_BUILD_MEMORY' "${BUILD_DIR}/rules/config.user" 2>/dev/null; then
            {
                echo "# Auto-generated by setup_and_deploy_vs.sh"
                echo "SONIC_BUILD_MEMORY = ${DETECTED_BUILD_MEMORY}"
                echo "SONIC_CONFIG_BUILD_JOBS = ${SONIC_BUILD_JOBS}"
                echo "DEFAULT_BUILD_LOG_TIMESTAMP = simple"
            } >> "${BUILD_DIR}/rules/config.user"
            log_info "Wrote ${BUILD_DIR}/rules/config.user (memory=${DETECTED_BUILD_MEMORY}, jobs=${SONIC_BUILD_JOBS})"
        fi
    fi

    cd "$BUILD_DIR"

    # One-time init after clone
    make init 2>/dev/null || true

    # Configure for VS platform
    log_info "Running: make configure PLATFORM=${PLATFORM}"
    make configure PLATFORM="${PLATFORM}"

    # Build all VS images
    log_info "Running: make SONIC_BUILD_JOBS=${SONIC_BUILD_JOBS} BUILD_SKIP_TEST=${BUILD_SKIP_TEST} all"
    if ! make SONIC_BUILD_JOBS="${SONIC_BUILD_JOBS}" \
             BUILD_SKIP_TEST="${BUILD_SKIP_TEST}" \
             all; then
        log_error "Build failed. Check ${BUILD_DIR}/build.log for details."
        return 1
    fi

    # Verify the expected artifacts were produced
    local expected=(
        "${BUILD_DIR}/target/docker-gbsyncd-vs.gz"
        "${BUILD_DIR}/target/docker-database.gz"
        "${BUILD_DIR}/target/docker-orchagent.gz"
    )
    local missing_artifacts=()
    for f in "${expected[@]}"; do
        [ -s "$f" ] || missing_artifacts+=("$(basename "$f")")
    done
    if [ ${#missing_artifacts[@]} -gt 0 ]; then
        log_error "Build did not produce: ${missing_artifacts[*]}"
        return 1
    fi

    log_success "Build complete. Images in ${BUILD_DIR}/target/"
}

load_images_from_archive() {
    local archive_dir="${1:-}"

    # Try multiple possible locations
    if [ -z "$archive_dir" ]; then
        if [ -d "${TARGET_DIR}" ] && ls "${TARGET_DIR}"/docker-*.gz 1>/dev/null 2>&1; then
            archive_dir="${TARGET_DIR}"
        elif [ -f "${PROJECT_DIR}/sonic-buildimage.vs.zip" ]; then
            log_info "Extracting sonic-buildimage.vs.zip..."
            mkdir -p "${PROJECT_DIR}/sonic-extracted"
            unzip -q "${PROJECT_DIR}/sonic-buildimage.vs.zip" \
                -d "${PROJECT_DIR}/sonic-extracted/" 2>/dev/null || true
            archive_dir="${TARGET_DIR}"
        elif [ -d "${BUILD_DIR}/target" ] && ls "${BUILD_DIR}/target"/docker-*.gz 1>/dev/null 2>&1; then
            archive_dir="${BUILD_DIR}/target"
        else
            log_error "No image archive found. Checked:"
            log_error "  - ${TARGET_DIR}"
            log_error "  - ${PROJECT_DIR}/sonic-buildimage.vs.zip"
            log_error "  - ${BUILD_DIR}/target"
            return 1
        fi
    fi

    if [ ! -d "$archive_dir" ]; then
        log_error "Archive directory not found: ${archive_dir}"
        return 1
    fi

    local count=0
    for img in "$archive_dir"/docker-*.gz; do
        [ -s "$img" ] || continue  # skip empty files
        local basename
        basename=$(basename "$img")
        log_info "Loading: ${basename}"
        docker load -i "$img" 2>/dev/null && count=$((count + 1)) || \
            log_warn "Failed to load: ${basename}"
    done

    log_success "Loaded ${count} Docker images from ${archive_dir}"
    return 0
}

###############################################################################
# Image acquisition strategy
###############################################################################
acquire_images() {
    log_step "Acquiring SONiC VS Docker images..."

    # Strategy 1: Check if images are already loaded in Docker
    local required_images=(
        "docker-gbsyncd-vs:latest"
        "docker-database:latest"
        "docker-orchagent:latest"
        "docker-eventd:latest"
        "docker-lldp:latest"
    )

    local all_present=true
    for img in "${required_images[@]}"; do
        if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${img}$"; then
            log_info "  ✓ ${img} (already present)"
        else
            all_present=false
            log_warn "  ✗ ${img} (missing)"
        fi
    done

    if $all_present; then
        log_success "All required images already present in Docker"
        return 0
    fi

    # Strategy 2: Load from extracted .gz files
    if ls "${TARGET_DIR}"/docker-*.gz 1>/dev/null 2>&1 || \
       ls "${BUILD_DIR}/target"/docker-*.gz 1>/dev/null 2>&1; then
        log_info "Found .gz image archives, loading..."
        load_images_from_archive && return 0
    fi

    # Strategy 3: Extract from zip
    if [ -f "${PROJECT_DIR}/sonic-buildimage.vs.zip" ]; then
        log_info "Found sonic-buildimage.vs.zip, extracting and loading..."
        load_images_from_archive && return 0
    fi

    # Strategy 4: Build from source
    log_info "No pre-built images found. Building from source..."
    clone_build_repo
    build_vs_images
    return 0
}

###############################################################################
# Deployment directory & config setup
###############################################################################
setup_directories() {
    log_step "Setting up deployment directories..."
    mkdir -p "${CONFIG_DIR}" "${HWSKU_DIR}" "${LOG_DIR}" "${LOG_DIR}/supervisor" "${LOG_DIR}/redis"
    chmod -R 777 "${LOG_DIR}"
    log_success "Directories created"
}

create_database_config() {
    if [ -f "${CONFIG_DIR}/database_config.json" ]; then
        log_info "database_config.json already exists, skipping"
        return 0
    fi

    log_info "Creating database_config.json..."
    cat > "${CONFIG_DIR}/database_config.json" << 'DBEOF'
{
    "INSTANCES": {
        "redis": {
            "hostname": "127.0.0.1",
            "port": 6379
        }
    },
    "DATABASES": {
        "APPL_DB":         {"id": 0,  "separator": ":", "instance": "redis"},
        "ASIC_DB":         {"id": 1,  "separator": ":", "instance": "redis"},
        "COUNTERS_DB":     {"id": 2,  "separator": ":", "instance": "redis"},
        "LOGLEVEL_DB":     {"id": 3,  "separator": ":", "instance": "redis"},
        "CONFIG_DB":       {"id": 4,  "separator": "|", "instance": "redis"},
        "PFC_WD_DB":       {"id": 5,  "separator": ":", "instance": "redis"},
        "STATE_DB":        {"id": 6,  "separator": "|", "instance": "redis"},
        "GB_ASIC_DB":      {"id": 9,  "separator": ":", "instance": "redis"},
        "GB_COUNTERS_DB":  {"id": 10, "separator": ":", "instance": "redis"},
        "FLEX_COUNTER_DB": {"id": 11, "separator": "|", "instance": "redis"},
        "TIMEZONE_DB":     {"id": 12, "separator": ":", "instance": "redis"},
        "VOQ_INBAND_DB":   {"id": 13, "separator": "|", "instance": "redis"},
        "CHASSIS_APP_DB":  {"id": 14, "separator": ":", "instance": "redis"},
        "CHASSIS_STATE_DB":{"id": 15, "separator": "|", "instance": "redis"},
        "RESTORE_DB":      {"id": 16, "separator": "|", "instance": "redis"},
        "DEVICEBASIC_DB":  {"id": 17, "separator": ":", "instance": "redis"},
        "PEER_SWITCH":     {"id": 18, "separator": "|", "instance": "redis"},
        "MGMENT_DB":       {"id": 19, "separator": "|", "instance": "redis"},
        "GPS_DB":          {"id": 20, "separator": "|", "instance": "redis"}
    }
}
DBEOF
    log_success "database_config.json created"
}

create_config_db() {
    if [ -f "${CONFIG_DIR}/config_db.json" ]; then
        log_info "config_db.json already exists, skipping"
        return 0
    fi

    log_info "Creating config_db.json..."
    cat > "${CONFIG_DIR}/config_db.json" << 'CFGEOF'
{
    "DEVICE_METADATA": {
        "localhost": {
            "hostname": "sonic-vs",
            "platform": "x86_64-nokia_midas-r0",
            "asic_type": "vs",
            "mac": "00:1b:21:34:56:78",
            "switch_type": "router",
            "datetime_format": "Tue Feb  6 13:45:21 +0000 2018",
            "default_bgp_status": "disabled",
            "default_gearbox_mode": "N/A",
            "is_deployed": "no",
            "is_usb_present": "no",
            "mgmt_mac": "00:1b:21:34:56:78",
            "region": "Region_1",
            "subrole": "N/A",
            "tz": "UTC",
            "type": "LeafRouter",
            "watchdog_action": "N/A"
        }
    },
    "PORT": {
        "Ethernet0":  {"admin_status": "up", "lanes": "0",    "speed": 1000, "mtu": 9100},
        "Ethernet4":  {"admin_status": "up", "lanes": "4",    "speed": 1000, "mtu": 9100},
        "Ethernet8":  {"admin_status": "up", "lanes": "8",    "speed": 1000, "mtu": 9100},
        "Ethernet12": {"admin_status": "up", "lanes": "12",   "speed": 1000, "mtu": 9100}
    },
    "PORT_CONFIG": {
        "Ethernet0":  {"alias": "Ethernet0",  "index": 0,  "lanes": "0",    "speed": 1000},
        "Ethernet4":  {"alias": "Ethernet4",  "index": 1,  "lanes": "4",    "speed": 1000},
        "Ethernet8":  {"alias": "Ethernet8",  "index": 2,  "lanes": "8",    "speed": 1000},
        "Ethernet12": {"alias": "Ethernet12", "index": 3,  "lanes": "12",   "speed": 1000}
    },
    "FEATURE": {
        "bgp":      {"enabled": "true",  "state": "enabled"},
        "gbsyncd":  {"enabled": "true",  "state": "enabled"},
        "gnmi":     {"enabled": "true",  "state": "enabled"},
        "telemetry":{"enabled": "true",  "state": "enabled"},
        "lldp":     {"enabled": "true",  "state": "enabled"},
        "pfcwd":    {"enabled": "false", "state": "disabled"},
        "swss":     {"enabled": "true",  "state": "enabled"}
    },
    "SYSTEM_HEALTH": {
        "process": {
            "syncd":      {"checkpoint": 180, "condition": "running", "high_priority": true},
            "orchagent":  {"checkpoint": 180, "condition": "running", "high_priority": true},
            "teamd":      {"checkpoint": 180, "condition": "running", "high_priority": false},
            "frr":        {"checkpoint": 180, "condition": "running", "high_priority": false},
            "radv":       {"checkpoint": 180, "condition": "running", "high_priority": false},
            "mgmt-framework": {"checkpoint": 180, "condition": "running", "high_priority": false},
            "database":   {"checkpoint": 180, "condition": "running", "high_priority": true}
        }
    },
    "DEVICEBASIC_CONFIG": {
        "switch_info": {
            "device_type": "LeafRouter",
            "device_sub_type": "N/A",
            "device_region": "Region_1"
        }
    }
}
CFGEOF
    log_success "config_db.json created"
}

create_constants() {
    if [ -f "${CONFIG_DIR}/constants.yml" ]; then
        log_info "constants.yml already exists, skipping"
        return 0
    fi

    log_info "Creating constants.yml..."
    cat > "${CONFIG_DIR}/constants.yml" << 'CONSTEOF'
ASIC_SDK_VERSION: sonic
ASIC_VENDOR: vs
CONSTEOF
    log_success "constants.yml created"
}

create_port_config() {
    if [ -f "${HWSKU_DIR}/port_config.ini" ]; then
        log_info "port_config.ini already exists, skipping"
        return 0
    fi

    log_info "Creating port_config.ini..."
    cat > "${HWSKU_DIR}/port_config.ini" << 'PORTEOF'
[PORT]
alias         index     lanes               speed
Ethernet0     0         0                   1000
Ethernet4     1         4                   1000
Ethernet8     2         8                   1000
Ethernet12    3         12                  1000
PORTEOF
    log_success "port_config.ini created"
}

setup_config() {
    log_step "Setting up configuration files..."
    create_database_config
    create_config_db
    create_constants
    create_port_config
    log_success "Configuration setup complete"
}

###############################################################################
# Network setup
###############################################################################
setup_network() {
    log_step "Setting up virtual network..."

    # Create bridge if it doesn't exist
    if ! ip link show sonic-vs-br &>/dev/null 2>&1; then
        ip link add name sonic-vs-br type bridge 2>/dev/null || true
        ip addr add 10.0.0.1/24 dev sonic-vs-br 2>/dev/null || true
        ip link set sonic-vs-br up 2>/dev/null || true
        log_info "Created bridge sonic-vs-br (10.0.0.1/24)"
    else
        log_info "Bridge sonic-vs-br already exists"
    fi

    # Create veth pairs for virtual ports
    local veth_pairs=("veth0" "veth4" "veth8" "veth12")
    local host_pairs=("host-veth0" "host-veth4" "host-veth8" "host-veth12")

    for i in "${!veth_pairs[@]}"; do
        local veth="${veth_pairs[$i]}"
        local host="${host_pairs[$i]}"

        if ! ip link show "$veth" &>/dev/null 2>&1; then
            ip link add "$veth" type veth peer name "$host" 2>/dev/null || true
            ip link set "$veth" up 2>/dev/null || true
            ip link set "$host" up 2>/dev/null || true
            ip link set "$host" master sonic-vs-br 2>/dev/null || true
            log_info "Created veth pair: $veth <-> $host (on sonic-vs-br)"
        else
            log_info "veth pair $veth already exists"
        fi
    done

    log_success "Network setup complete"
}

###############################################################################
# Deploy containers
###############################################################################
wait_for_redis() {
    log_info "Waiting for Redis to be ready..."
    local retries=60
    while [ $retries -gt 0 ]; do
        if docker exec sonic-database redis-cli ping 2>/dev/null | grep -q "PONG"; then
            log_success "Redis is ready!"
            return 0
        fi
        retries=$((retries - 1))
        sleep 1
    done
    log_error "Redis failed to start within 60 seconds"
    return 1
}

load_config_to_redis() {
    log_info "Loading configuration into CONFIG_DB (Redis db4)..."

    docker exec sonic-vs python3 -c "
import redis, json, sys

config_file = '/etc/sonic/config_db.json'
try:
    with open(config_file) as f:
        config = json.load(f)
except Exception as e:
    print(f'Error reading config file: {e}', file=sys.stderr)
    sys.exit(1)

r = redis.Redis(host='127.0.0.1', port=6379, db=4, socket_timeout=5)

# Clear existing config
try:
    r.flushdb()
except Exception as e:
    print(f'Warning: could not flush db4: {e}')

loaded = 0
for table, entries in config.items():
    if isinstance(entries, dict):
        for key, fields in entries.items():
            redis_key = f'{table}|{key}'
            if isinstance(fields, dict):
                cleaned = {}
                for k, v in fields.items():
                    if isinstance(v, (list, dict)):
                        cleaned[k] = json.dumps(v)
                    else:
                        cleaned[k] = str(v)
                try:
                    r.hset(redis_key, mapping=cleaned)
                    loaded += 1
                except Exception as e:
                    print(f'Warning: could not set {redis_key}: {e}')

print(f'Loaded {loaded} keys into CONFIG_DB')
" 2>&1

    if [ $? -eq 0 ]; then
        log_success "Configuration loaded into CONFIG_DB"
    else
        log_warn "Config load script had issues — check output above"
    fi
}

cleanup_existing() {
    log_info "Cleaning up existing deployment..."
    docker compose -f "${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true

    # Remove stale network interfaces
    for veth in veth0 veth4 veth8 veth12; do
        ip link del "$veth" 2>/dev/null || true
    done
    for host in host-veth0 host-veth4 host-veth8 host-veth12; do
        ip link del "$host" 2>/dev/null || true
    done
    ip link del sonic-vs-br 2>/dev/null || true
    log_info "Cleanup complete"
}

deploy() {
    log_info "=========================================="
    log_info "Deploying SONiC Virtual Switch (OCS VS)"
    log_info "=========================================="

    # Pre-flight checks
    check_docker_running
    check_required_images

    # Stop existing
    cleanup_existing

    # Setup
    setup_directories
    setup_config
    setup_network

    # Start containers
    log_info "Starting SONiC VS containers via docker-compose..."
    docker compose -f "${COMPOSE_FILE}" up -d

    # Wait for Redis
    wait_for_redis

    # Load config
    load_config_to_redis

    # Show status
    echo ""
    log_success "=========================================="
    log_success "SONiC VS deployment complete!"
    log_success "=========================================="
    echo ""
    show_status
    echo ""
    log_info "Quick commands:"
    log_info "  Status:  bash $0 --status"
    log_info "  Logs:    bash $0 --logs"
    log_info "  Shell:   docker exec -it sonic-vs bash"
    log_info "  Stop:    bash $0 --stop"
    log_info "  Config:  docker exec sonic-vs sonic-db-cli CONFIG_DB keys '*'"
}

###############################################################################
# Status & helpers
###############################################################################
check_docker_running() {
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi
    if ! docker info &>/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        exit 1
    fi
}

check_required_images() {
    log_info "Checking required Docker images..."
    local required_images=(
        "docker-gbsyncd-vs:latest"
        "docker-database:latest"
        "docker-orchagent:latest"
        "docker-eventd:latest"
        "docker-lldp:latest"
    )

    local missing=()
    for img in "${required_images[@]}"; do
        if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${img}$"; then
            log_info "  ✓ ${img}"
        else
            missing+=("$img")
            log_warn "  ✗ ${img} (missing)"
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing images: ${missing[*]}"
        log_error "Run: bash $0 --build-only  (or load images manually)"
        exit 1
    fi
}

show_status() {
    log_info "SONiC VS Status"
    log_info "=========================================="

    echo ""
    log_info "Containers:"
    docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || log_warn "No containers running"

    echo ""
    log_info "Network interfaces:"
    ip link show 2>/dev/null | grep -E '(sonic-vs|veth|host-veth|br-sonic)' || \
        log_warn "No VS interfaces found"

    echo ""
    log_info "Redis ping:"
    docker exec sonic-database redis-cli ping 2>/dev/null || log_warn "Redis not responding"

    echo ""
    log_info "CONFIG_DB keys (sample):"
    docker exec sonic-vs sonic-db-cli CONFIG_DB keys '*' 2>/dev/null | head -20 || \
        log_warn "No CONFIG_DB keys found"
}

###############################################################################
# Full dependency install
###############################################################################
install_all_deps() {
    log_info "=========================================="
    log_info "Installing all dependencies"
    log_info "=========================================="
    check_root
    check_os
    install_packages
    install_python_tools
    install_docker
    log_success "All dependencies installed!"
}

###############################################################################
# Main entry point
###############################################################################
main() {
    local action="${1:---deploy}"

    case "$action" in
        --deps-only)
            install_all_deps
            ;;
        --build-only)
            check_root
            acquire_images
            ;;
        --deploy-only)
            deploy
            ;;
        --stop)
            docker compose -f "${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
            log_info "SONiC VS stopped"
            ;;
        --cleanup)
            cleanup_existing
            log_info "Full cleanup complete"
            ;;
        --status)
            show_status
            ;;
        --dashboard)
            detect_build_resources
            show_dashboard
            ;;
        --logs)
            shift
            docker compose -f "${COMPOSE_FILE}" logs -f "$@" 2>/dev/null || \
                log_warn "No containers running"
            ;;
        --help|-h)
            echo "Usage: bash $0 [ACTION]"
            echo ""
            echo "Actions:"
            echo "  (no arg)          Full setup: deps + images + deploy (default)"
            echo "  --deps-only       Install system dependencies only"
            echo "  --build-only      Build or load Docker images only"
            echo "  --deploy-only     Deploy containers (images must exist)"
            echo "  --stop            Stop all containers"
            echo "  --cleanup         Stop + remove networks + interfaces"
            echo "  --status          Show container & network status"
            echo "  --dashboard       Show progress and next actions"
            echo "  --logs [service]  Follow container logs"
            echo "  --show-build-info Preview detected build resources (no build)"
            echo ""
            echo "Environment variables:"
            echo "  SONIC_BRANCH         Git branch to clone (default: master)"
            echo "  SONIC_BUILD_JOBS     Parallel build jobs (default: auto-detect)"
            echo "  SONIC_BUILD_MEMORY   Container memory limit (default: auto-detect)"
            echo "  PLATFORM             ASIC platform (default: vs)"
            echo "  BUILD_SKIP_TEST      Skip tests during build (default: y)"
            ;;
        --show-build-info)
            log_info "Detecting host resources..."
            detect_build_resources
            echo ""
            echo "  CPUs detected:        ${DETECTED_CPUS}"
            echo "  RAM detected:         ${DETECTED_RAM_GB} GB"
            echo "  Free disk:            ${DETECTED_DISK_GB} GB"
            echo "  → SONIC_BUILD_JOBS:   ${SONIC_BUILD_JOBS}"
            echo "  → SONIC_BUILD_MEMORY: ${DETECTED_BUILD_MEMORY}"
            echo ""
            local est_ram=$(( SONIC_BUILD_JOBS * 6 + 4 ))
            local est_disk=$(( SONIC_BUILD_JOBS * 30 + 70 ))
            echo "  Estimated build cost: ~${est_ram} GB RAM, ~${est_disk} GB disk"
            echo "  Estimated build time: ~$(( 180 / SONIC_BUILD_JOBS )) minutes (VS platform)"
            ;;
        *)
            # Default: full setup + deploy
            log_info "=========================================="
            log_info "SONiC VS — Full Setup & Deploy"
            log_info "=========================================="
            echo ""

            # Phase 1: Dependencies
            log_step "Phase 1: Checking dependencies..."
            check_root
            check_os
            install_packages
            install_python_tools
            install_docker

            # Phase 2: Images
            log_step "Phase 2: Acquiring Docker images..."
            acquire_images

            # Phase 3: Deploy
            log_step "Phase 3: Deploying SONiC VS..."
            deploy
            ;;
    esac
}

main "$@"
