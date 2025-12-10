# ApexData Agent - Quick Deployment Guide

ApexData Agent is an agent for collecting Kubernetes and system metrics with data forwarding via OpenTelemetry.

## Requirements

### General Requirements
- Client name (e.g., `demo1`, `demo2`)
- Password for authentication
- Cluster/node name

**Note**: For host deployment, the endpoint is automatically built as `{client-name}.collector.eu.apexdata.ai:444`

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
./deploy-kubernetes.sh --interactive
```

### Manual Installation

1. Set environment variables:
```bash
export APEXDATA_OTEL_ENDPOINT="oteldemo.collector.eu.apexdata.ai:444"
export APEXDATA_BASE64_CREDENTIALS="$(echo -n 'username:password' | base64)"
export APEXDATA_CLUSTER_NAME="production-cluster"
```

**Note**: Endpoint format is `{client-name}.collector.eu.apexdata.ai:444`, where client name is also used as username.

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
./deploy-kubernetes.sh --status
```

### Removal

```bash
./deploy-kubernetes.sh --uninstall
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
sudo ./install-single-host.sh install
```

The script will prompt for:
- **Client name** (e.g., `demo1`, `demo2`)
  - Endpoint will be built automatically: `{name}.collector.eu.apexdata.ai:444`
  - This name will also be used as username for authentication
- **Password** for Basic Auth
- **Node name** (default: hostname)
- **Optional monitoring endpoints**:
  - Redis address (e.g., `127.0.0.1:6379`)
  - PHP-FPM status URL (e.g., `https://example.com/fpm-status`)
  - MySQL DSN (e.g., `user:password@tcp(127.0.0.1:3306)`)

### Service Management

```bash
# Start
sudo ./install-single-host.sh start

# Stop
sudo ./install-single-host.sh stop

# Restart
sudo ./install-single-host.sh restart

# Status
./install-single-host.sh status

# Logs
./install-single-host.sh logs
```

### Service Removal

```bash
sudo ./install-single-host.sh uninstall
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
./deploy-kubernetes.sh --help

# Host
./install-single-host.sh help
```

## Usage Examples

### Kubernetes - Full Cycle
```bash
# Deployment
./deploy-kubernetes.sh --interactive

# Verification
./deploy-kubernetes.sh --status

# Removal if needed
./deploy-kubernetes.sh --uninstall
```

### Host - Full Cycle
```bash
# Installation (requires sudo)
sudo ./install-single-host.sh install

# Start
sudo ./install-single-host.sh start

# Check status
./install-single-host.sh status

# View logs
./install-single-host.sh logs
```


### 📤 Data Flow

```
Agents → collect metrics/logs/traces
   ↓
Prometheus registry → metric aggregation
   ↓
OpenTelemetry SDK → export in OTLP format
   ↓
OTel Collector (in cluster) → buffering and batch sending
   ↓
Endpoint → receive data via HTTPS with Basic Auth
```

All data is sent using the OpenTelemetry Protocol (OTLP).
