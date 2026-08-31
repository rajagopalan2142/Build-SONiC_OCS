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
#   bash setup_and_deploy_vs.sh
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

# Build image source (sonic-ocs upstream repo)
BUILD_REPO="https://github.com/sonic-ocs/sonic-buildimage.git"
BUILD_BRANCH="${SONIC_BRANCH:-ocs-dev}"
BUILD_DIR="${PROJECT_DIR}/sonic-buildimage"
TARGET_DIR="${PROJECT_DIR}/sonic-extracted/sonic-buildimage.vs/target"

# Build settings (override via environment)
PLATFORM="${PLATFORM:-ocs-kvm}"
BUILD_SKIP_TEST="${BUILD_SKIP_TEST:-y}"

###############################################################################
# OCS-KVM Container Definitions
###############################################################################
# Core containers required for OCS-KVM platform
CORE_IMAGES=(
    "docker-syncd-ocs-kvm:latest"
    "docker-orchagent:latest"
    "docker-database:latest"
    "docker-eventd:latest"
    "docker-lldp:latest"
    "docker-sonic-gnmi:latest"
)

# Optional containers (enabled via build flags)
OPTIONAL_IMAGES=(
    "docker-sonic-bmp:latest"
    "docker-sonic-otel:latest"
    "docker-nat:latest"
    "docker-mux:latest"
    "docker-sflow:latest"
    "docker-sonic-mgmt-framework:latest"
    "docker-snmp:latest"
    "docker-fpm-frr:latest"
    "docker-stp:latest"
    "docker-macsec:latest"
    "docker-iccpd:latest"
    "docker-router-advertiser:latest"
    "docker-platform-monitor:latest"
    "docker-sysmgr:latest"
    "docker-teamd:latest"
)

# All images (core + optional)
ALL_IMAGES=("${CORE_IMAGES[@]}" "${OPTIONAL_IMAGES[@]}")

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

progress_format_eta() {
    local seconds="$1"
    if [ "$seconds" -lt 0 ]; then
        seconds=0
    fi
    local h=$((seconds / 3600))
    local m=$(((seconds % 3600) / 60))
    local s=$((seconds % 60))
    printf '%02d:%02d:%02d' "$h" "$m" "$s"
}

progress_render() {
    local message="${1:-Running}"

    printf '\033[H\033[2K'
    printf '%s' "$message"
    printf '\n\033[2K'
    printf '%s' '----------------------------------------'
    printf '\033[2;1H'
}

progress_start() {
    PROGRESS_TOTAL_START_EPOCH=$SECONDS
    printf '\033[?25l\033[H\033[2J'
    progress_render "Initializing OCS-KVM setup"
}

progress_finish() {
    progress_render "Deployment complete"
    printf '\n\033[?25h'
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

    # Install system-wide when run as root so all users (including the build user) can use j2
    if [ "$(id -u)" -eq 0 ]; then
        pip3 install --quiet jinjanator 2>/dev/null || \
            pip3 install --user --quiet jinjanator 2>/dev/null || \
            log_warn "Could not install jinjanator"
    else
        pip3 install --user --quiet jinjanator 2>/dev/null || \
            pip3 install --quiet jinjanator 2>/dev/null || \
            log_warn "Could not install jinjanator"
    fi

    # Verify j2 command works for root
    if command -v j2 &>/dev/null || [ -f /usr/local/bin/j2 ] || [ -f /root/.local/bin/j2 ] || [ -f ~/.local/bin/j2 ]; then
        log_success "j2/jinjanator installed"
    else
        log_warn "j2 command not found in PATH — may need to add ~/.local/bin to PATH"
    fi

    # Also install for the build user (may differ from root when script runs via sudo)
    local build_user
    build_user="${SUDO_USER:-$(whoami)}"
    if [ "$(id -u)" -eq 0 ] && [ -n "$build_user" ] && [ "$build_user" != "root" ]; then
        local build_home
        build_home="$(eval echo ~"$build_user")"
        local build_user_j2="${build_home}/.local/bin/j2"
        if [ ! -f "$build_user_j2" ] && ! command -v j2 &>/dev/null; then
            log_info "Installing jinjanator for build user '${build_user}'..."
            sudo -H -u "$build_user" pip3 install --user --quiet jinjanator 2>/dev/null || \
                log_warn "Could not install jinjanator for user '${build_user}'"
        fi
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
fix_build_ownership() {
    local run_user="${SUDO_USER:-$(whoami)}"
    local run_group
    run_group="$(id -gn "$run_user" 2>/dev/null || echo "$run_user")"

    if [ "$(id -u)" -eq 0 ] && [ -n "$run_user" ] && [ "$run_user" != "root" ] && [ -d "$BUILD_DIR" ]; then
        log_info "Fixing build-tree ownership for '${run_user}' before make..."
        chown -R "$run_user:$run_group" "$BUILD_DIR" 2>/dev/null || true
        find "$BUILD_DIR" -type d -exec chmod u+rwx,g+rwx,o+rx {} + 2>/dev/null || true
        find "$BUILD_DIR" -type f -exec chmod u+rw,g+r,o+r {} + 2>/dev/null || true
    fi
}

clone_build_repo() {
    log_step "Setting up sonic-buildimage repository..."

    local clone_user
    clone_user="${SUDO_USER:-$(whoami)}"
    local clone_home
    clone_home="$(eval echo ~"$clone_user")"

    if [ -d "${BUILD_DIR}/.git" ]; then
        log_info "Repository already cloned at ${BUILD_DIR}"

        # Fix ownership if the repo was cloned by root (e.g. from a prior run)
        local repo_owner
        repo_owner=$(stat -c '%U' "$BUILD_DIR" 2>/dev/null || echo "root")
        if [ "$repo_owner" != "$clone_user" ]; then
            log_info "Fixing ownership of ${BUILD_DIR} (was ${repo_owner}, needs ${clone_user})"
            chown -R "$clone_user:$(id -gn "$clone_user" 2>/dev/null || echo "$clone_user")" "$BUILD_DIR" 2>/dev/null || true
        fi

        # Also fix well-known directories that the build creates as root
        for dir in "${BUILD_DIR}/target" \
                   "${BUILD_DIR}/sonic-slave-bookworm" \
                   "${BUILD_DIR}/sonic-slave-bullseye" \
                   "${BUILD_DIR}/sonic-slave-buster" \
                   "${BUILD_DIR}/fsroot.docker.bookworm" \
                   "${BUILD_DIR}/fsroot.docker.bullseye" \
                   "${BUILD_DIR}/fsroot.docker.buster" \
                   "${BUILD_DIR}/fsroot.docker.trixie"; do
            if [ -d "$dir" ]; then
                local d_owner
                d_owner=$(stat -c '%U' "$dir" 2>/dev/null || echo "root")
                if [ "$d_owner" != "$clone_user" ]; then
                    chown -R "$clone_user:$(id -gn "$clone_user" 2>/dev/null || echo "$clone_user")" "$dir" 2>/dev/null || true
                fi
            fi
        done

        fix_build_ownership
        cd "$BUILD_DIR"
        HOME="$clone_home" git fetch --all 2>/dev/null || true
        HOME="$clone_home" git checkout "$BUILD_BRANCH" 2>/dev/null || true
        HOME="$clone_home" git pull origin "$BUILD_BRANCH" 2>/dev/null || true
        HOME="$clone_home" git submodule update --init --recursive 2>/dev/null || true
        fix_build_ownership
        log_info "Repository updated"
        return 0
    fi

    log_info "Cloning sonic-buildimage (branch: ${BUILD_BRANCH}) as user '${clone_user}'..."
    # Clone as the original user so that `make` (which refuses root) works
    HOME="$clone_home" git clone --recurse-submodules -b "$BUILD_BRANCH" "$BUILD_REPO" "$BUILD_DIR"
    chown -R "$clone_user:$(id -gn "$clone_user" 2>/dev/null || echo "$clone_user")" "$BUILD_DIR" 2>/dev/null || true
    fix_build_ownership
    log_success "Repository cloned"
}

build_vs_images() {
    log_step "Building SONiC images..."

    # The SONiC Makefile refuses to run as root.
    # When called via sudo, delegate all `make` steps to the original user.
    local run_user
    run_user="${SUDO_USER:-$(whoami)}"
    local run_home
    run_home="$(eval echo ~"$run_user")"
    local run_as=""
    if [ "$(id -u)" -eq 0 ] && [ -n "$run_user" ] && [ "$run_user" != "root" ]; then
        run_as="sudo -H -u ${run_user}"
        log_info "Running make as '${run_user}' (root builds are blocked by SONiC Makefile)"
    fi

    # Auto-tune jobs and memory for this host (idempotent, env overrides win)
    detect_build_resources

    log_info "Platform: ${PLATFORM}"
    log_info "Build jobs: ${SONIC_BUILD_JOBS}"
    log_info "Build memory: ${DETECTED_BUILD_MEMORY}"
    log_info "Skip tests: ${BUILD_SKIP_TEST}"
    log_info "Build dir: ${BUILD_DIR}"

    # --- Build log file for HUD to read ---
    BUILD_LOG="${BUILD_DIR}/build.log"

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
        # Ensure the build user owns the rules dir
        chown -R "${run_user}:$(id -gn "$run_user" 2>/dev/null || echo "$run_user")" "${BUILD_DIR}/rules" 2>/dev/null || true
    fi

    # Fix ownership of stale root-owned directories from prior failed builds.
    # The build creates many subdirectories as root before the non-root check fires;
    # fix them here so the non-root `make` steps can write into them.
    if [ "$(id -u)" -eq 0 ] && [ -n "$run_user" ] && [ "$run_user" != "root" ]; then
        log_info "Fixing ownership of build artifacts in ${BUILD_DIR}..."
        chown -R "${run_user}:$(id -gn "$run_user" 2>/dev/null || echo "$run_user")" \
            "${BUILD_DIR}/target" \
            "${BUILD_DIR}/sonic-slave-bookworm" \
            "${BUILD_DIR}/sonic-slave-bullseye" \
            "${BUILD_DIR}/sonic-slave-buster" \
            "${BUILD_DIR}/sonic-slave-trixie" \
            "${BUILD_DIR}/fsroot.docker.bookworm" \
            "${BUILD_DIR}/fsroot.docker.bullseye" \
            "${BUILD_DIR}/fsroot.docker.buster" \
            "${BUILD_DIR}/fsroot.docker.trixie" \
            2>/dev/null || true
    fi

    # Ensure ~/.local/bin is in PATH for the build user (j2/jinjanator lives there from pip3 --user)
    local build_path="${run_home}/.local/bin:${PATH}"
    if [ -n "$run_as" ] && [ -d "${run_home}/.local/bin" ]; then
        log_info "Ensuring ${run_home}/.local/bin is in PATH for build (j2/jinjanator)"
    fi

    # One-time init after clone
    fix_build_ownership
    log_info "Running: ${run_as} make init"
    ${run_as} HOME="${run_home}" PATH="${build_path}" make -C "$BUILD_DIR" init 2>/dev/null || true

    # Configure for OCS-KVM platform with all features enabled
    log_info "Running: ${run_as} make configure PLATFORM=${PLATFORM} \
        INCLUDE_SYSTEM_GNMI=y \
        INCLUDE_SYSTEM_EVENTD=y \
        INCLUDE_SYSTEM_BMP=y \
        INCLUDE_SYSTEM_OTEL=y \
        INCLUDE_DHCP_RELAY=y \
        INCLUDE_DHCP_SERVER=y \
        INCLUDE_MACSEC=y \
        INCLUDE_STP=y \
        INCLUDE_ICCPD=y \
        SONIC_INCLUDE_RESTAPI=y \
        SONIC_INCLUDE_MUX=y \
        ENABLE_DIALOUT=y"
    ${run_as} HOME="${run_home}" PATH="${build_path}" make -C "$BUILD_DIR" \
        configure \
        PLATFORM="${PLATFORM}" \
        INCLUDE_SYSTEM_GNMI=y \
        INCLUDE_SYSTEM_EVENTD=y \
        INCLUDE_SYSTEM_BMP=y \
        INCLUDE_SYSTEM_OTEL=y \
        INCLUDE_DHCP_RELAY=y \
        INCLUDE_DHCP_SERVER=y \
        INCLUDE_MACSEC=y \
        INCLUDE_STP=y \
        INCLUDE_ICCPD=y \
        SONIC_INCLUDE_RESTAPI=y \
        SONIC_INCLUDE_MUX=y \
        ENABLE_DIALOUT=y

    # Build all images
    log_info "Running: ${run_as} make SONIC_BUILD_JOBS=${SONIC_BUILD_JOBS} BUILD_SKIP_TEST=${BUILD_SKIP_TEST} all"
    if ! ${run_as} HOME="${run_home}" PATH="${build_path}" make -C "$BUILD_DIR" \
             SONIC_BUILD_JOBS="${SONIC_BUILD_JOBS}" \
             BUILD_SKIP_TEST="${BUILD_SKIP_TEST}" \
             all; then
        log_error "Build failed. Check ${BUILD_DIR}/build.log for details."
        return 1
    fi

    # Verify core OCS-KVM artifacts were produced
    local expected=(
        "${BUILD_DIR}/target/docker-syncd-ocs-kvm.gz"
        "${BUILD_DIR}/target/docker-orchagent.gz"
        "${BUILD_DIR}/target/docker-database.gz"
        "${BUILD_DIR}/target/docker-eventd.gz"
        "${BUILD_DIR}/target/docker-lldp.gz"
        "${BUILD_DIR}/target/docker-sonic-gnmi.gz"
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
# Check which required images are present in Docker
# Sets global MISSING_IMAGES array with any that are absent
###############################################################################
check_missing_images() {
    local required_images=("${CORE_IMAGES[@]}")

    MISSING_IMAGES=()
    for img in "${required_images[@]}"; do
        if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${img}$"; then
            log_info "  ✓ ${img} (present)"
        else
            MISSING_IMAGES+=("$img")
            log_warn "  ✗ ${img} (missing)"
        fi
    done
}

###############################################################################
# Image acquisition strategy
###############################################################################
acquire_images() {
    log_step "Acquiring SONiC VS Docker images..."

    # Check what we already have
    check_missing_images

    if [ ${#MISSING_IMAGES[@]} -eq 0 ]; then
        log_success "All required images already present in Docker"
        return 0
    fi

    # Strategy 1: Load from extracted .gz files (may partially fill the gap)
    if ls "${TARGET_DIR}"/docker-*.gz 1>/dev/null 2>&1 || \
       ls "${BUILD_DIR}/target"/docker-*.gz 1>/dev/null 2>&1; then
        log_info "Found .gz image archives, loading..."
        load_images_from_archive
    fi

    # Strategy 2: Extract from zip (may partially fill the gap)
    if [ -f "${PROJECT_DIR}/sonic-buildimage.vs.zip" ]; then
        log_info "Found sonic-buildimage.vs.zip, extracting and loading..."
        load_images_from_archive
    fi

    # Re-check after loading — if all images are now present, we're done
    check_missing_images
    if [ ${#MISSING_IMAGES[@]} -eq 0 ]; then
        log_success "All required images are now present in Docker"
        return 0
    fi

    # Strategy 3: Build missing images from source
    log_info "Still missing ${#MISSING_IMAGES[@]} images: ${MISSING_IMAGES[*]}"
    log_info "Building missing images from source..."
    clone_build_repo
    build_vs_images

    # After building, load the newly built images into Docker
    log_info "Loading newly built images into Docker..."
    load_images_from_archive "${BUILD_DIR}/target"

    # Final check
    check_missing_images
    if [ ${#MISSING_IMAGES[@]} -gt 0 ]; then
        log_error "Images still missing after build: ${MISSING_IMAGES[*]}"
        log_error "Check build logs in ${BUILD_DIR}/build.log"
        return 1
    fi

    log_success "All required images are now available in Docker"
    return 0
}

###############################################################################
# Generate docker-compose.yml for OCS-KVM deployment
###############################################################################
create_docker_compose() {
    if [ -f "${COMPOSE_FILE}" ]; then
        log_info "docker-compose.yml already exists, skipping"
        return 0
    fi

    log_info "Creating docker-compose.yml for OCS-KVM platform..."

    # Port mappings (override via environment)
    local GNMI_PORT="${GNMI_PORT:-50051}"
    local BMP_PORT="${BMP_PORT:-50052}"
    local OTLP_GRPC_PORT="${OTLP_GRPC_PORT:-4317}"
    local OTLP_HTTP_PORT="${OTLP_HTTP_PORT:-4318}"
    local SNMP_PORT="${SNMP_PORT:-161}"
    local SFLOW_PORT="${SFLOW_PORT:-6343}"
    local MGMT_REST_PORT="${MGMT_REST_PORT:-8080}"
    local MGMT_CLI_PORT="${MGMT_CLI_PORT:-22}"

    cat > "${COMPOSE_FILE}" << COMPOSEEOF
# SONiC Virtual Switch (OCS-KVM) — Docker Compose
# Platform: ocs-kvm
# Repository: https://github.com/sonic-ocs/sonic-buildimage (branch: ocs-dev)
#
# Core Containers:
#   - docker-syncd-ocs-kvm   : Syncd daemon with OCS-KVM SAI
#   - docker-orchagent       : Orchestration agent (SwSS)
#   - docker-database        : Redis database
#   - docker-eventd          : Event daemon
#   - docker-lldp            : Link Layer Discovery Protocol
#   - docker-sonic-gnmi      : gNMI interface (port ${GNMI_PORT})
#
# Optional Containers (enabled via build flags):
#   - docker-sonic-bmp       : BGP Monitoring Protocol (port ${BMP_PORT})
#   - docker-sonic-otel      : OpenTelemetry collector (ports ${OTLP_GRPC_PORT}/${OTLP_HTTP_PORT})
#   - docker-snmp            : SNMP agent (port ${SNMP_PORT}/udp)
#   - docker-sflow           : sFlow monitoring (port ${SFLOW_PORT}/udp)
#   - docker-sonic-mgmt-framework : Management framework (port ${MGMT_REST_PORT})
#   - docker-nat             : NAT support
#   - docker-mux             : MUX for dual ToR
#   - docker-fpm-frr         : Forwarding Plane Manager (FRR)
#   - docker-stp             : Spanning Tree Protocol
#   - docker-macsec          : MACsec support
#   - docker-iccpd           : MCLAG support
#   - docker-router-advertiser : IPv6 Router Advertisements

services:
  # ========================================================================
  # Infrastructure
  # ========================================================================

  sonic-database:
    image: docker-database:latest
    container_name: sonic-database
    restart: unless-stopped
    networks:
      sonic-vs-net:
        ipv4_address: 10.255.0.2
    volumes:
      - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
      - ${LOG_DIR}/redis:/var/log/redis
    environment:
      - REDIS_LOGLEVEL=notice
    command: >
      bash -c "
        supervisord -c /etc/supervisor/supervisord.conf
      "
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
    privileged: true

  # ========================================================================
  # Core OCS-KVM Containers
  # ========================================================================

  sonic-syncd:
    image: docker-syncd-ocs-kvm:latest
    container_name: sonic-syncd
    restart: unless-stopped
    networks:
      sonic-vs-net:
        ipv4_address: 10.255.0.3
    volumes:
      - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
      - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
      - ${CONFIG_DIR}/constants.yml:/etc/sonic/constants.yml
      - ${HWSKU_DIR}:/usr/share/sonic/hwsku
      - ${LOG_DIR}/supervisor:/var/log/supervisor
    environment:
      - SONIC_DB_HOST=10.255.0.2
      - SONIC_DB_PORT=6379
      - SAI_PROFILE_PATH=/etc/sonic/
      - ANSIBLE_HOST_KEY_CHECKING=False
    depends_on:
      sonic-database:
        condition: service_healthy
    privileged: true

  sonic-orchagent:
    image: docker-orchagent:latest
    container_name: sonic-orchagent
    restart: unless-stopped
    networks:
      sonic-vs-net:
        ipv4_address: 10.255.0.4
    volumes:
      - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
      - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
      - ${CONFIG_DIR}/constants.yml:/etc/sonic/constants.yml
      - ${HWSKU_DIR}:/usr/share/sonic/hwsku
      - ${LOG_DIR}/supervisor:/var/log/supervisor
    environment:
      - SONIC_DB_HOST=10.255.0.2
      - SONIC_DB_PORT=6379
      - SAI_PROFILE_PATH=/etc/sonic/
    depends_on:
      sonic-database:
        condition: service_healthy
      sonic-syncd:
        condition: service_started
    privileged: true

  sonic-eventd:
    image: docker-eventd:latest
    container_name: sonic-eventd
    restart: unless-stopped
    networks:
      sonic-vs-net:
        ipv4_address: 10.255.0.5
    volumes:
      - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
      - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
      - ${LOG_DIR}/supervisor:/var/log/supervisor
    environment:
      - SONIC_DB_HOST=10.255.0.2
      - SONIC_DB_PORT=6379
    depends_on:
      sonic-database:
        condition: service_healthy
    privileged: true

  sonic-lldp:
    image: docker-lldp:latest
    container_name: sonic-lldp
    restart: unless-stopped
    networks:
      sonic-vs-net:
        ipv4_address: 10.255.0.6
    volumes:
      - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
      - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
      - ${LOG_DIR}/supervisor:/var/log/supervisor
    environment:
      - SONIC_DB_HOST=10.255.0.2
      - SONIC_DB_PORT=6379
    depends_on:
      sonic-database:
        condition: service_healthy
    privileged: true

  # ========================================================================
  # gNMI — Configuration & Telemetry Interface
  # ========================================================================

  sonic-gnmi:
    image: docker-sonic-gnmi:latest
    container_name: sonic-gnmi
    restart: unless-stopped
    networks:
      sonic-vs-net:
        ipv4_address: 10.255.0.7
    ports:
      - "${GNMI_PORT}:50051"
    volumes:
      - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
      - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
      - ${LOG_DIR}/supervisor:/var/log/supervisor
    environment:
      - SONIC_DB_HOST=10.255.0.2
      - SONIC_DB_PORT=6379
      - GNMI_PORT=50051
      - ENABLE_NATIVE=true
    depends_on:
      sonic-database:
        condition: service_healthy
      sonic-orchagent:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f gnmi || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
    privileged: true

  # ========================================================================
  # Optional Containers (commented out — enable as needed)
  # ========================================================================

  # BGP Monitoring Protocol
  # sonic-bmp:
  #   image: docker-sonic-bmp:latest
  #   container_name: sonic-bmp
  #   restart: unless-stopped
  #   networks:
  #     sonic-vs-net:
  #       ipv4_address: 10.255.0.8
  #   ports:
  #     - "${BMP_PORT}:50052"
  #   volumes:
  #     - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
  #     - ${LOG_DIR}/supervisor:/var/log/supervisor
  #   environment:
  #     - SONIC_DB_HOST=10.255.0.2
  #     - SONIC_DB_PORT=6379
  #   depends_on:
  #     sonic-database:
  #       condition: service_healthy
  #   privileged: true

  # OpenTelemetry Collector
  # sonic-otel:
  #   image: docker-sonic-otel:latest
  #   container_name: sonic-otel
  #   restart: unless-stopped
  #   networks:
  #     sonic-vs-net:
  #       ipv4_address: 10.255.0.9
  #   ports:
  #     - "${OTLP_GRPC_PORT}:4317"
  #     - "${OTLP_HTTP_PORT}:4318"
  #   volumes:
  #     - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
  #     - ${LOG_DIR}/supervisor:/var/log/supervisor
  #   environment:
  #     - SONIC_DB_HOST=10.255.0.2
  #     - SONIC_DB_PORT=6379
  #   depends_on:
  #     sonic-database:
  #       condition: service_healthy
  #   privileged: true

  # SNMP Agent
  # sonic-snmp:
  #   image: docker-snmp:latest
  #   container_name: sonic-snmp
  #   restart: unless-stopped
  #   networks:
  #     sonic-vs-net:
  #       ipv4_address: 10.255.0.10
  #   ports:
  #     - "${SNMP_PORT}:${SNMP_PORT}/udp"
  #   volumes:
  #     - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
  #     - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
  #     - ${LOG_DIR}/supervisor:/var/log/supervisor
  #   environment:
  #     - SONIC_DB_HOST=10.255.0.2
  #     - SONIC_DB_PORT=6379
  #   depends_on:
  #     sonic-database:
  #       condition: service_healthy
  #   privileged: true

  # sFlow Monitoring
  # sonic-sflow:
  #   image: docker-sflow:latest
  #   container_name: sonic-sflow
  #   restart: unless-stopped
  #   networks:
  #     sonic-vs-net:
  #       ipv4_address: 10.255.0.11
  #   ports:
  #     - "${SFLOW_PORT}:${SFLOW_PORT}/udp"
  #   volumes:
  #     - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
  #     - ${LOG_DIR}/supervisor:/var/log/supervisor
  #   environment:
  #     - SONIC_DB_HOST=10.255.0.2
  #     - SONIC_DB_PORT=6379
  #   depends_on:
  #     sonic-database:
  #       condition: service_healthy
  #   privileged: true

  # Management Framework (CLI + REST)
  # sonic-mgmt-framework:
  #   image: docker-sonic-mgmt-framework:latest
  #   container_name: sonic-mgmt-framework
  #   restart: unless-stopped
  #   networks:
  #     sonic-vs-net:
  #       ipv4_address: 10.255.0.12
  #   ports:
  #     - "${MGMT_REST_PORT}:8080"
  #     - "${MGMT_CLI_PORT}:22"
  #   volumes:
  #     - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
  #     - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
  #     - ${LOG_DIR}/supervisor:/var/log/supervisor
  #   environment:
  #     - SONIC_DB_HOST=10.255.0.2
  #     - SONIC_DB_PORT=6379
  #   depends_on:
  #     sonic-database:
  #       condition: service_healthy
  #   privileged: true

  # Forwarding Plane Manager (FRR)
  # sonic-fpm-frr:
  #   image: docker-fpm-frr:latest
  #   container_name: sonic-fpm-frr
  #   restart: unless-stopped
  #   networks:
  #     sonic-vs-net:
  #       ipv4_address: 10.255.0.13
  #   volumes:
  #     - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
  #     - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
  #     - ${LOG_DIR}/supervisor:/var/log/supervisor
  #   environment:
  #     - SONIC_DB_HOST=10.255.0.2
  #     - SONIC_DB_PORT=6379
  #   depends_on:
  #     sonic-database:
  #       condition: service_healthy
  #   privileged: true

  # NAT Support
  # sonic-nat:
  #   image: docker-nat:latest
  #   container_name: sonic-nat
  #   restart: unless-stopped
  #   networks:
  #     sonic-vs-net:
  #       ipv4_address: 10.255.0.14
  #   volumes:
  #     - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
  #     - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
  #     - ${LOG_DIR}/supervisor:/var/log/supervisor
  #   environment:
  #     - SONIC_DB_HOST=10.255.0.2
  #     - SONIC_DB_PORT=6379
  #   depends_on:
  #     sonic-database:
  #       condition: service_healthy
  #   privileged: true

  # MUX for dual ToR
  # sonic-mux:
  #   image: docker-mux:latest
  #   container_name: sonic-mux
  #   restart: unless-stopped
  #   networks:
  #     sonic-vs-net:
  #       ipv4_address: 10.255.0.15
  #   volumes:
  #     - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
  #     - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
  #     - ${LOG_DIR}/supervisor:/var/log/supervisor
  #   environment:
  #     - SONIC_DB_HOST=10.255.0.2
  #     - SONIC_DB_PORT=6379
  #   depends_on:
  #     sonic-database:
  #       condition: service_healthy
  #   privileged: true

  # Spanning Tree Protocol
  # sonic-stp:
  #   image: docker-stp:latest
  #   container_name: sonic-stp
  #   restart: unless-stopped
  #   networks:
  #     sonic-vs-net:
  #       ipv4_address: 10.255.0.16
  #   volumes:
  #     - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
  #     - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
  #     - ${LOG_DIR}/supervisor:/var/log/supervisor
  #   environment:
  #     - SONIC_DB_HOST=10.255.0.2
  #     - SONIC_DB_PORT=6379
  #   depends_on:
  #     sonic-database:
  #       condition: service_healthy
  #   privileged: true

  # MACsec Support
  # sonic-macsec:
  #   image: docker-macsec:latest
  #   container_name: sonic-macsec
  #   restart: unless-stopped
  #   networks:
  #     sonic-vs-net:
  #       ipv4_address: 10.255.0.17
  #   volumes:
  #     - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
  #     - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
  #     - ${LOG_DIR}/supervisor:/var/log/supervisor
  #   environment:
  #     - SONIC_DB_HOST=10.255.0.2
  #     - SONIC_DB_PORT=6379
  #   depends_on:
  #     sonic-database:
  #       condition: service_healthy
  #   privileged: true

  # MCLAG Support (ICCPD)
  # sonic-iccpd:
  #   image: docker-iccpd:latest
  #   container_name: sonic-iccpd
  #   restart: unless-stopped
  #   networks:
  #     sonic-vs-net:
  #       ipv4_address: 10.255.0.18
  #   volumes:
  #     - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
  #     - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
  #     - ${LOG_DIR}/supervisor:/var/log/supervisor
  #   environment:
  #     - SONIC_DB_HOST=10.255.0.2
  #     - SONIC_DB_PORT=6379
  #   depends_on:
  #     sonic-database:
  #       condition: service_healthy
  #   privileged: true

  # IPv6 Router Advertisements
  # sonic-router-advertiser:
  #   image: docker-router-advertiser:latest
  #   container_name: sonic-router-advertiser
  #   restart: unless-stopped
  #   networks:
  #     sonic-vs-net:
  #       ipv4_address: 10.255.0.19
  #   volumes:
  #     - ${CONFIG_DIR}/database_config.json:/etc/sonic/database_config.json
  #     - ${CONFIG_DIR}/config_db.json:/etc/sonic/config_db.json
  #     - ${LOG_DIR}/supervisor:/var/log/supervisor
  #   environment:
  #     - SONIC_DB_HOST=10.255.0.2
  #     - SONIC_DB_PORT=6379
  #   depends_on:
  #     sonic-database:
  #       condition: service_healthy
  #   privileged: true

networks:
  sonic-vs-net:
    driver: bridge
    ipam:
      config:
        - subnet: 10.255.0.0/24
COMPOSEEOF

    log_success "docker-compose.yml created at ${COMPOSE_FILE}"
    log_info "Core containers: syncd-ocs-kvm, orchagent, database, eventd, lldp, gnmi"
    log_info "Optional containers are commented out — uncomment in ${COMPOSE_FILE} to enable"
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

wait_for_gnmi() {
    log_info "Waiting for gNMI service to be ready..."
    local retries=30
    local gnmi_port="${GNMI_PORT:-50051}"
    while [ $retries -gt 0 ]; do
        if docker exec sonic-gnmi pgrep -f gnmi &>/dev/null 2>&1; then
            log_success "gNMI service is ready on port ${gnmi_port}!"
            return 0
        fi
        retries=$((retries - 1))
        sleep 2
    done
    log_warn "gNMI service may not be fully ready yet — check logs with: bash $0 --logs sonic-gnmi"
    return 0
}

load_config_to_redis() {
    log_info "Loading configuration into CONFIG_DB (Redis db4)..."

    # Use sonic-database container to load config into Redis
    docker exec sonic-database python3 -c "
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
    create_docker_compose
    setup_network

    # Start containers
    log_info "Starting SONiC VS containers via docker-compose..."
    docker compose -f "${COMPOSE_FILE}" up -d

    # Wait for Redis
    wait_for_redis

    # Load config
    load_config_to_redis

    # Wait for gNMI to be ready
    wait_for_gnmi

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
    log_info "  Shell:   docker exec -it sonic-orchagent bash"
    log_info "  gNMI:    grpcurl -plaintext localhost:${GNMI_PORT:-50051} sonic.proto.gnmi.GNMI/Capabilities"
    log_info "  Stop:    bash $0 --stop"
    log_info "  Config:  docker exec sonic-database redis-cli -n 4 keys '*'"
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
        "docker-syncd-ocs-kvm:latest"
        "docker-database:latest"
        "docker-orchagent:latest"
        "docker-eventd:latest"
        "docker-lldp:latest"
        "docker-sonic-gnmi:latest"
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
        log_warn "Missing images: ${missing[*]}"
        log_info "Automatically building missing images from source..."
        echo ""

        # Ensure repo is available
        if [ ! -d "${BUILD_DIR}/.git" ]; then
            clone_build_repo
        fi

        # Build all images (make will skip already-built ones)
        build_vs_images

        # Re-check after build
        local still_missing=()
        for img in "${missing[@]}"; do
            if ! docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${img}$"; then
                still_missing+=("$img")
            fi
        done

        if [ ${#still_missing[@]} -gt 0 ]; then
            log_error "Images still missing after build: ${still_missing[*]}"
            log_error "Check build logs in ${BUILD_DIR}/build.log"
            exit 1
        fi

        log_success "All required images are now available"
        echo ""
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
# Main entry point
###############################################################################
main() {
    log_info "=========================================="
    log_info "SONiC VS — Full Setup & Deploy"
    log_info "=========================================="
    echo ""

    progress_start

    progress_render "Checking dependencies"
    check_root
    check_os
    install_packages
    install_python_tools
    install_docker

    progress_render "Cloning and building OCS images"
    acquire_images

    progress_render "Deploying OCS-KVM stack"
    deploy

    progress_finish
}

main
