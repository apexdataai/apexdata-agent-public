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

No build dependencies required -- the binary is statically linked.

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
- Optional: Redis, PHP-FPM, MySQL, PostgreSQL metrics and schema metadata

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

The chart deploys the rolling `latest` agent image by default; every release
also publishes an immutable short-sha tag you can pin instead — see
[Upgrading](helm/apexdata-agent/README.md#upgrading) in the chart README.
Cluster Events are exported by a single lease-coordinated instance (the agent
Deployment), not once per node — see
[Kubernetes Events Export](helm/apexdata-agent/README.md#kubernetes-events-export).

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

The manifest follows the rolling `latest` agent image and carries the same
role split as the chart: the cluster-level Deployment is the single
lease-coordinated Kubernetes Events exporter, node shards and the
unscheduled-pods watcher stay idle.

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

## Database Monitoring

### PostgreSQL

The agent can connect to PostgreSQL instances to collect performance metrics and schema metadata for the SQL Explain feature.

**Performance metrics** (collected at scrape interval): `pg_stat_activity`, `pg_stat_database`, `pg_stat_user_tables`, `pg_stat_statements`, `pg_stat_replication`.

**Schema metadata** (collected hourly): table definitions, indexes, column types, and column statistics from system catalogs. This data powers the Explain feature -- offline query plan prediction without connecting to your database at analysis time.

### Configuration

Pass the PostgreSQL DSN via `--postgres-dsn`. Multiple instances can be comma-separated:

```bash
# Single instance
--postgres-dsn='postgres://user:pass@host:5432/dbname?sslmode=disable'

# Multiple instances
--postgres-dsn='postgres://user:pass@host1:5432/db1,postgres://user:pass@host2:5432/db2'
```

### Agent Flags

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--postgres-dsn` | string | `""` | PostgreSQL connection string (comma-separated for multiple instances) |
| `--postgres-auto-dsn-template` | string | `""` | DSN template with `{addr}` for auto-discovered instances |
| `--pg-schema-collect-enabled` | bool | `true` | Enable hourly schema metadata collection for Explain |
| `--pg-schema-collect-interval` | duration | `1h` | Schema metadata collection interval |

### Schema Collection Details

The schema collector runs 4 read-only catalog queries per cycle:
- `pg_class` -- table row counts and page counts
- `pg_indexes` -- index definitions (method, columns, uniqueness)
- `information_schema.columns` -- column names, types, nullability
- `pg_stats` -- column statistics (null fraction, distinct values, correlation)

Data is emitted as an OTLP log record (~30 KB gzipped) with `source=pg_schema` attribute.

### Required PostgreSQL Permissions

```sql
-- Minimum required grants
GRANT CONNECT ON DATABASE <dbname> TO <agent_role>;
GRANT pg_read_all_stats TO <agent_role>;  -- for complete pg_stats visibility
```

Without `pg_read_all_stats`, column statistics will only be available for tables owned by the agent's role.

### Kubernetes Deployment

For Kubernetes, pass the DSN via `shard.extraArgs` in your Helm values:

```yaml
shard:
  extraArgs:
    - "--postgres-dsn=postgres://user:pass@pg-host:5432/dbname?sslmode=disable"
```

Or via `helm install`:

```bash
helm install apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai \
  --create-namespace \
  --set apexdata.clientName="your-client-name" \
  --set apexdata.password="your-password" \
  --set apexdata.clusterName="your-cluster-name" \
  --set 'shard.extraArgs[0]=--postgres-dsn=postgres://user:pass@pg-host:5432/dbname?sslmode=disable'
```

To disable schema collection while keeping performance metrics:

```yaml
shard:
  extraArgs:
    - "--postgres-dsn=postgres://user:pass@pg-host:5432/dbname?sslmode=disable"
    - "--pg-schema-collect-enabled=false"
```

## Support

- Documentation: https://github.com/apexdataai/apexdata-agent-public
- Helm chart details: [helm/apexdata-agent/README.md](helm/apexdata-agent/README.md)
- Support: https://apexdata.ai
