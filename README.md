# SONiC OCS Setup and Deployment Script

This repository contains a Bash automation script that prepares a Linux host, builds the required SONiC OCS container images, creates the deployment configuration, and brings up a SONiC Optical Circuit Switch (OCS) environment using Docker Compose.

The script is designed to handle the full workflow in one run:

- install host dependencies
- install Docker and Docker Compose
- clone or refresh the SONiC build repository
- build missing OCS images or load prebuilt archives
- create deployment config and network files
- launch the SONiC OCS containers
- load configuration into Redis CONFIG_DB
- report status

## Files

- `setup_and_deploy_vs.sh` — main deployment automation script
- `sonic-buildimage/` — cloned SONiC build tree used for image generation
- `deployment/` — generated config, logs, and Compose files at runtime

## Requirements

Before running the script, make sure the host meets these requirements:

- Linux-based system (Ubuntu/Debian recommended)
- Root privileges or `sudo`
- Internet access for package installation and git clone
- Docker support enabled on the host
- Enough disk space and RAM for the SONiC build

A typical host should have:

- 16GB+ RAM recommended
- 100GB+ free disk space recommended
- modern CPU with multiple cores

## Usage

Run the script as root or with sudo:

```bash
sudo ./setup_and_deploy_vs.sh
```

The script will:

1. detect the OS
2. install base system packages
3. install Python tools
4. install Docker + Compose
5. clone or update `sonic-buildimage`
6. build the required `ocs-kvm` images
7. generate the deployment config
8. start the virtual switch services

## What it builds and deploys

The script is configured for the `ocs-kvm` platform and targets the core SONiC containers:

- `docker-syncd-ocs-kvm`
- `docker-orchagent`
- `docker-database`
- `docker-eventd`
- `docker-lldp`
- `docker-sonic-gnmi`

Optional images are also defined in the script but are left commented in the Compose file unless you enable them manually.

## Generated deployment layout

The script creates a deployment directory structure like this:

```text
deployment/
├── config/
│   ├── config_db.json
│   ├── constants.yml
│   ├── database_config.json
│── hwsku/
│   └── port_config.ini
├── logs/
│   ├── redis/
│   └── supervisor/
├── docker-compose.yml
```

## Build behavior

The script tries the following order to get the required Docker images:

1. check whether the required images already exist in Docker
2. look for prebuilt `.gz` image archives in known locations
3. extract and load archives from a zip file if present
4. clone the SONiC build repository and build the images from source

If a build is required, it runs `make` against the `sonic-buildimage` repository for the `ocs-kvm` platform with feature flags enabled for GNMI, eventd, BMP, OTEL, DHCP, MACsec, STP, ICCPD, and others.

## Environment overrides

You can override some build settings using environment variables before running the script:

```bash
export SONIC_BRANCH=ocs-dev
export PLATFORM=ocs-kvm
export SONIC_BUILD_JOBS=8
export SONIC_BUILD_MEMORY=16g
export BUILD_SKIP_TEST=y
sudo -E ./setup_and_deploy_vs.sh
```

Useful variables:

- `SONIC_BRANCH` — SONiC branch to checkout
- `PLATFORM` — target platform name
- `SONIC_BUILD_JOBS` — build parallelism
- `SONIC_BUILD_MEMORY` — build memory value for SONiC config
- `BUILD_SKIP_TEST` — whether to skip tests during the image build

## Deployment flow

Once images are available, the script:

- cleans up any existing VS deployment
- creates the Linux bridge and veth ports
- creates the Docker Compose stack
- starts the containers in the background
- waits for Redis to become healthy
- loads the runtime configuration into `CONFIG_DB`
- waits for the gNMI container to be ready
- prints a summary and runtime status

## Useful commands after deployment

After the script completes, you can inspect the environment with:

```bash
docker compose -f ./deployment/docker-compose.yml ps

docker exec -it sonic-orchagent bash

docker exec sonic-database redis-cli -n 4 keys '*'
```

For gNMI, the script prints a suggested command similar to:

```bash
grpcurl -plaintext localhost:50051 sonic.proto.gnmi.GNMI/Capabilities
```

## Troubleshooting

### Script says Docker is missing or not running

Check that Docker is installed and the daemon is active:

```bash
docker info
```

### Build is slow or fails

The script attempts to auto-tune build jobs and memory, but you may need to adjust them:

```bash
export SONIC_BUILD_JOBS=4
export SONIC_BUILD_MEMORY=8g
sudo -E ./setup_and_deploy_vs.sh
```

### Images are missing

Re-run the script; it automatically rebuilds missing required images.

### gNMI is not ready

Check the container logs:

```bash
docker logs sonic-gnmi
```

## Notes

- The script is designed for lab/test environments and virtual switch deployments.
- It may take a long time to build SONiC images, especially on smaller machines.
- The script uses Docker Compose to orchestrate the VS stack and creates a simulated network layer for the switch.

## License

This project is provided for local automation and lab use. Check the repository contents for the applicable licensing terms before distribution or reuse.
