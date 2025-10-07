# ApexData Agent - Quick Deployment Guide

ApexData Agent is an agent for collecting Kubernetes and system metrics with data forwarding via OpenTelemetry.

## Requirements

### General Requirements
- Access to ApexData endpoint (e.g., `clientname-otel.app.apexdata.ai`)
- Credentials (username:password)
- Cluster/node name

### For Kubernetes Deployment
- `kubectl` installed and configured
- `envsubst` (gettext package)
- Cluster administrator rights
- Access to Kubernetes cluster

### For Host Deployment
- Root privileges (sudo)
- systemd
- `apexdata-agent` binary file
- System dependencies: `sudo apt install -y --fix-missing libsystemd-dev gcc build-essential`

## Kubernetes Deployment

### Quick Start (Recommended)

```bash
# Interactive installation
./deploy.sh --interactive
```

### Manual Installation

1. Set environment variables:
```bash
export APEXDATA_OTEL_ENDPOINT="clientname-otel.app.apexdata.ai"
export APEXDATA_BASE64_CREDENTIALS="$(echo -n 'username:password' | base64)"
export APEXDATA_CLUSTER_NAME="production-cluster"
```

2. Deploy the agent:
```bash
envsubst < universal-deployment.yml | kubectl apply -f -
```

### Deployment Verification

```bash
# Check pod status
kubectl get pods -n apexdata-ai

# View logs
kubectl logs -n apexdata-ai deployment/otel-collector
kubectl logs -n apexdata-ai deployment/apexdata-agent

# Or use the script
./deploy.sh --status
```

### Removal

```bash
./deploy.sh --uninstall
```

## Host Deployment (systemd)

### System Preparation

```bash
# Install system dependencies (Ubuntu/Debian)
sudo apt install -y --fix-missing libsystemd-dev gcc build-essential
```

### Service Installation

```bash
# Place the apexdata-agent binary file in the current directory
sudo ./service-manager.sh install
```

The script will prompt for:
- OpenTelemetry endpoint (e.g., `domain:port`)
- Basic Auth token (base64 encoded)
- Node name (default: hostname)

### Service Management

```bash
# Start
sudo ./service-manager.sh start

# Stop
sudo ./service-manager.sh stop

# Restart
sudo ./service-manager.sh restart

# Status
./service-manager.sh status

# Logs
./service-manager.sh logs
```

### Configuration Update

```bash
sudo ./service-manager.sh update
```

### Service Removal

```bash
sudo ./service-manager.sh uninstall
```

## Deployment Components

### Kubernetes
- **apexdata-agent**: main agent for cluster metrics collection
- **apexdata-agent-unscheduled-pods**: tracking unscheduled pods
- **apexdata-agent-shard**: DaemonSet for collecting metrics from each node
- **otel-collector**: collector for forwarding data to your endpoint

### Host (systemd)
- **apexdata-agent**: systemd service for system metrics collection
- Automatic restart on failures
- Logging via systemd journal

## Support

For help:
```bash
# Kubernetes
./deploy.sh --help

# Host
./service-manager.sh help
```

## Usage Examples

### Kubernetes - Full Cycle
```bash
# Deployment
./deploy.sh --interactive

# Verification
./deploy.sh --status

# Removal if needed
./deploy.sh --uninstall
```

### Host - Full Cycle
```bash
# Installation (requires sudo)
sudo ./service-manager.sh install

# Start
sudo ./service-manager.sh start

# Check status
./service-manager.sh status

# View logs
./service-manager.sh logs
```
