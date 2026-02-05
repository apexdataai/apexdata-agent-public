# ApexData Agent - Deployment Guide

ApexData Agent collects Kubernetes and system metrics, logs, and traces with data forwarding via OpenTelemetry Protocol (OTLP).

## Requirements

- Client name (e.g., `demo1`, `demo2`) -- also used as username
- Password for Basic Auth authentication
- Cluster or node name

The endpoint is automatically built as `https://{client-name}.collector.eu.apexdata.ai:444`.

## Single Host Deployment

For standalone servers (VMs, bare-metal) -- no Kubernetes required. The agent installs as a systemd service and collects system metrics, process data, and optional application metrics (Redis, PHP-FPM, MySQL).

### Prerequisites

```bash
# Ubuntu/Debian
sudo apt install -y --fix-missing libsystemd-dev gcc build-essential
```

### Install

One command -- downloads the binary, verifies SHA256 checksum, creates a systemd service:

```bash
curl -fsSL http://grogh.apexdata.ai/install.sh | sudo bash -s -- install
```

The script will interactively prompt for:
- **Client name** -- used as username and to build the endpoint (`{name}.collector.eu.apexdata.ai:444`)
- **Password** -- for Basic Auth
- **Node name** -- defaults to hostname
- **Optional endpoints** -- Redis, PHP-FPM status URL, MySQL DSN

### How It Works

After installation the agent runs as a systemd service (`apexdata-agent.service`):

```
apexdata-agent ──(OTLP/gRPC + TLS + Basic Auth)──> Remote ApexData Collector
```

- Binary location: `/usr/local/bin/apexdata-agent`
- Service file: `/etc/systemd/system/apexdata-agent.service`
- Runs as root (needed for system metrics collection)
- Automatic restart on failures (`RestartSec=10`)
- Logs to systemd journal

The agent collects:
- System metrics (CPU, memory, disk, network)
- Process lifecycle and resource usage
- Network connections and protocol-level metrics (HTTP, DNS, gRPC, databases)
- eBPF-based container and process tracing
- Optional: Redis, PHP-FPM, MySQL metrics

### Management

All management is done via the same URL -- no need to store scripts locally:

```bash
# Start / Stop / Restart
curl -fsSL http://grogh.apexdata.ai/install.sh | sudo bash -s -- start
curl -fsSL http://grogh.apexdata.ai/install.sh | sudo bash -s -- stop
curl -fsSL http://grogh.apexdata.ai/install.sh | sudo bash -s -- restart

# Status and logs (no sudo needed)
curl -fsSL http://grogh.apexdata.ai/install.sh | bash -s -- status
curl -fsSL http://grogh.apexdata.ai/install.sh | bash -s -- logs
```

### Update

Downloads the latest binary, verifies checksum, replaces and restarts:

```bash
curl -fsSL http://grogh.apexdata.ai/install.sh | sudo bash -s -- update
```

### Uninstall

Stops the service, removes the binary and service file:

```bash
curl -fsSL http://grogh.apexdata.ai/install.sh | sudo bash -s -- uninstall
```

### Reconfiguration

To change configuration (client name, password, monitoring endpoints), uninstall and reinstall:

```bash
curl -fsSL http://grogh.apexdata.ai/install.sh | sudo bash -s -- uninstall
curl -fsSL http://grogh.apexdata.ai/install.sh | sudo bash -s -- install
```

---

## Kubernetes Deployment (Helm) -- Recommended

The Helm chart supports two deployment modes controlled by `otelCollector.enabled`.

### Prerequisites

- Kubernetes 1.20+
- Helm 3.0+
- Cluster administrator rights

### Mode 1: Direct to Remote Endpoint (default)

Agents send data directly to the remote ApexData collector with TLS and Basic Auth. No intermediate collector needed.

```bash
helm install apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai \
  --create-namespace \
  --set apexdata.clientName="your-client-name" \
  --set apexdata.password="your-password" \
  --set apexdata.clusterName="your-cluster-name"
```

```
agent ─────────────┐
unscheduled-pods ──┼──(OTLP/gRPC + TLS + Basic Auth)──> Remote ApexData Collector
shard (per node) ──┘
```

### Mode 2: Via In-Cluster OTel Collector

Agents send data to a local in-cluster OTel Collector (without auth). The collector buffers, batches, and forwards to the remote endpoint with auth.

```bash
helm install apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai \
  --create-namespace \
  --set apexdata.clientName="your-client-name" \
  --set apexdata.password="your-password" \
  --set apexdata.clusterName="your-cluster-name" \
  --set otelCollector.enabled=true
```

```
agent ─────────────┐
unscheduled-pods ──┼──(OTLP/gRPC, no auth)──> OTel Collector ──(OTLP/gRPC + TLS + Auth)──> Remote
shard (per node) ──┘                          (in-cluster)
```

### Flexible Collector Architecture

The agent can write to **any** OTLP-compatible endpoint. In collector mode, agents send data without authentication to a local collector, which handles routing and forwarding. This enables architectures where the client manages their own collector pipeline:

```
                         ┌──(OTLP + Basic Auth)──> ApexData Remote Collector
                         │
Agents ──(OTLP, no auth)──> Client's OTel Collector ──(remote_write)──> VictoriaMetrics (local)
                         │
                         └──(OTLP)──> Other destinations
```

The client can configure their collector to:
- Forward to the remote ApexData collector with authentication
- Send to local VictoriaMetrics / Prometheus endpoints
- Route to additional collectors or observability backends
- Apply custom processing, filtering, or sampling

See the [Helm chart README](helm/apexdata-agent/README.md) for detailed configuration options.

### Switching Between Modes

```bash
# Switch to collector mode
helm upgrade apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai -f my-values.yaml --set otelCollector.enabled=true

# Switch back to direct mode
helm upgrade apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai -f my-values.yaml --set otelCollector.enabled=false
```

### Verification

```bash
# Check pod status
kubectl get pods -n apexdata-ai

# View agent logs
kubectl logs -n apexdata-ai -l app.kubernetes.io/component=agent -f

# View shard logs
kubectl logs -n apexdata-ai -l app.kubernetes.io/component=shard -f

# View OTel collector logs (only in collector mode)
kubectl logs -n apexdata-ai -l app.kubernetes.io/component=otel-collector -f
```

### Removal

```bash
helm uninstall apexdata-agent --namespace apexdata-ai
kubectl delete namespace apexdata-ai  # optional
```

---

## Kubernetes Deployment (Manual)

For environments without Helm. Uses `envsubst` templating with a single YAML manifest.

### Prerequisites

- `kubectl` installed and configured
- `envsubst` (gettext package)
- Cluster administrator rights

### Installation

```bash
# Interactive (recommended)
./deploy-kubernetes.sh --interactive

# Or manual
export APEXDATA_OTEL_ENDPOINT="your-client-name.collector.eu.apexdata.ai:444"
export APEXDATA_BASE64_CREDENTIALS="$(echo -n 'your-client-name:your-password' | base64)"
export APEXDATA_CLUSTER_NAME="your-cluster-name"
envsubst < universal-deployment.yml | kubectl apply -f -
```

### Management

```bash
./deploy-kubernetes.sh --status     # Check status
./deploy-kubernetes.sh --uninstall  # Remove
```

---

## Components

### Kubernetes

| Component | Type | Description |
|-----------|------|-------------|
| **apexdata-agent** | Deployment | Cluster-wide K8s resource collection (non-privileged) |
| **apexdata-agent-unscheduled-pods** | Deployment | Tracking unscheduled pods |
| **apexdata-agent-shard** | DaemonSet | Node-level metrics via eBPF (privileged, per node) |
| **otel-collector** | Deployment | Buffering and forwarding (only with `otelCollector.enabled=true`) |

### Single Host

| Component | Description |
|-----------|-------------|
| **apexdata-agent** | systemd service collecting system and application metrics |

## Data Flow

All data is sent using the OpenTelemetry Protocol (OTLP).

**Single host:**
```
apexdata-agent ──(OTLP/gRPC + TLS + Basic Auth)──> Remote Collector
```

**Kubernetes direct mode (default):**
```
agent + shard + unscheduled-pods ──(OTLP/gRPC + TLS + Basic Auth)──> Remote Collector
```

**Kubernetes collector mode:**
```
agent + shard + unscheduled-pods ──(OTLP, no auth)──> OTel Collector ──(auth)──> Remote Collector
```

**Kubernetes custom pipeline:**
```
agent + shard + unscheduled-pods ──> Client's Collector ──> ApexData + VictoriaMetrics + ...
```

## Support

- Documentation: https://github.com/apexdataai/apexdata-agent-public
- Helm chart details: [helm/apexdata-agent/README.md](helm/apexdata-agent/README.md)
- Support: https://apexdata.ai
