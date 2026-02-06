# ApexData Agent Helm Chart

Helm chart for deploying ApexData Agent to Kubernetes clusters. Supports two deployment modes: direct to remote endpoint and via an intermediate OpenTelemetry Collector.

## Prerequisites

- Kubernetes 1.20+
- Helm 3.0+
- Cluster admin rights for RBAC resources

## Deployment Modes

The agent supports two telemetry delivery modes, controlled by the `otelCollector.enabled` parameter.

### Mode 1: Direct to Remote Endpoint (default)

```
otelCollector.enabled: false
```

All agent components (agent, shard, unscheduled-pods) send OTLP data **directly** to the remote ApexData collector endpoint via gRPC with TLS and Basic Auth.

```
Agents ──────(OTLP/gRPC + TLS + Basic Auth)──────> Remote Collector
                                                    (https://{clientName}.collector.eu.apexdata.ai:444)
```

This is the simplest setup. Each agent pod authenticates independently with the remote endpoint. Use this mode when:
- You want a minimal deployment without extra components
- Your cluster has direct outbound access to the remote endpoint
- You don't need local telemetry buffering or fan-out

### Mode 2: Via In-Cluster OTel Collector

```
otelCollector.enabled: true
```

All agent components send OTLP data to a **local in-cluster OTel Collector** (without authentication). The collector then forwards data to the remote endpoint with TLS and Basic Auth.

```
Agents ──(OTLP/gRPC, no auth)──> OTel Collector ──(OTLP/gRPC + TLS + Basic Auth)──> Remote Collector
                                  (in-cluster)                                        (remote)
```

Use this mode when:
- You want centralized telemetry buffering and batching in the cluster
- You want to fan-out data to multiple destinations (e.g., ApexData + local VictoriaMetrics)
- You prefer that agents don't hold credentials (only the collector does)
- You want to route data through your own observability pipeline
- You already have an OTel Collector in the cluster and want to reuse it

#### Custom Collector Configuration

The agent can send data to **any** OTLP-compatible collector -- not just the one deployed by this chart. This means the agent can write to:

- **ApexData remote collector** (with TLS + Basic Auth) -- direct mode
- **In-cluster OTel Collector deployed by this chart** (no auth) -- collector mode
- **Any existing OTel Collector in your cluster** (no auth or custom auth)
- **Local VictoriaMetrics** vmagent with OTLP receiver (no auth)
- **Any OTLP-compatible endpoint**

When the agent writes to a local collector without authentication, the collector itself is responsible for routing, authentication, and forwarding. This allows flexible architectures:

```
                         ┌──(OTLP + Basic Auth)──> ApexData Remote Collector
                         │
Agents ──(OTLP, no auth)──> Your OTel Collector ──(remote_write)──> VictoriaMetrics
                         │
                         └──(OTLP)──> Other destinations
```

The client can configure their own collector pipeline to:
- Forward to the remote ApexData collector with authentication
- Send to local VictoriaMetrics endpoints
- Route to additional collectors or observability backends
- Apply custom processing, filtering, or sampling

## Installation

### Quick Start (Direct Mode)

```bash
helm install apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai \
  --create-namespace \
  --set apexdata.clientName="your-client-name" \
  --set apexdata.password="your-password" \
  --set apexdata.clusterName="your-cluster-name"
```

### Quick Start (With Collector)

```bash
helm install apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai \
  --create-namespace \
  --set apexdata.clientName="your-client-name" \
  --set apexdata.password="your-password" \
  --set apexdata.clusterName="your-cluster-name" \
  --set otelCollector.enabled=true
```

### Using Values File (Recommended)

```bash
# Copy example values
cp helm/apexdata-agent/values.example.yaml my-values.yaml

# Edit with your configuration
# Required: apexdata.clientName, apexdata.password, apexdata.clusterName

# Install
helm install apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai \
  --create-namespace \
  -f my-values.yaml
```

### Switching Between Modes

You can switch modes at any time with `helm upgrade`:

```bash
# Switch to collector mode
helm upgrade apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai \
  -f my-values.yaml \
  --set otelCollector.enabled=true

# Switch back to direct mode
helm upgrade apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai \
  -f my-values.yaml \
  --set otelCollector.enabled=false
```

When switching to direct mode, the OTel Collector deployment and service are automatically removed by Helm. When switching to collector mode, they are automatically created.

### Using Infrastructure Repository (ArgoCD/FluxCD)

**ArgoCD Application:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apexdata-agent
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/infra-repo
    targetRevision: main
    path: charts/apexdata-agent
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: apexdata-ai
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Helmfile:**
```yaml
releases:
  - name: apexdata-agent
    chart: ./charts/apexdata-agent
    namespace: apexdata-ai
    createNamespace: true
    values:
      - values.yaml
    secrets:
      - secrets.yaml  # encrypted with sops/age
```

## Configuration

### Required Values

| Parameter | Description | Example |
|-----------|-------------|---------|
| `apexdata.clientName` | Client name (used as username and endpoint prefix) | `"mycompany"` |
| `apexdata.password` | Password for Basic Auth | `"your-password"` |
| `apexdata.clusterName` | Cluster identifier | `"production-cluster"` |

The endpoint is automatically built as `https://{clientName}.{endpointDomain}:{endpointPort}`.

### Global Settings

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.namespace` | Namespace for all resources | `apexdata-ai` |
| `global.createNamespace` | Create namespace if not exists | `true` |
| `global.imagePullSecrets` | Image pull secrets for private registries | `[]` |

### ApexData Endpoint

| Parameter | Description | Default |
|-----------|-------------|---------|
| `apexdata.endpointDomain` | Endpoint domain | `collector.eu.apexdata.ai` |
| `apexdata.endpointPort` | Endpoint port | `444` |

### OpenTelemetry Collector

| Parameter | Description | Default |
|-----------|-------------|---------|
| `otelCollector.enabled` | Deploy in-cluster OTel Collector | `false` |
| `otelCollector.replicas` | Number of replicas | `1` |
| `otelCollector.image.repository` | Image repository | `otel/opentelemetry-collector-contrib` |
| `otelCollector.image.tag` | Image tag | `0.114.0` |
| `otelCollector.resources.limits.cpu` | CPU limit | `1` |
| `otelCollector.resources.limits.memory` | Memory limit | `2Gi` |
| `otelCollector.resources.requests.cpu` | CPU request | `200m` |
| `otelCollector.resources.requests.memory` | Memory request | `400Mi` |
| `otelCollector.goMemLimit` | Go memory limit (GOMEMLIMIT) | `1600MiB` |
| `otelCollector.nodeSelector` | Node selector | `{}` |
| `otelCollector.tolerations` | Tolerations | `[]` |
| `otelCollector.affinity` | Affinity rules | `{}` |
| `otelCollector.podAnnotations` | Pod annotations | `{}` |
| `otelCollector.podDisruptionBudget.enabled` | Enable PDB | `false` |
| `otelCollector.podDisruptionBudget.minAvailable` | Min available pods | `1` |
| `otelCollector.service.type` | Service type | `ClusterIP` |
| `otelCollector.service.ports.grpc` | gRPC port | `4317` |
| `otelCollector.service.ports.http` | HTTP port | `4318` |

When `otelCollector.enabled=true`:
- Agents send data to `{release-name}-otel-collector:{grpc-port}` without auth
- The collector receives data on ports 4317 (gRPC) and 4318 (HTTP)
- The collector batches (10000 items / 10s) and forwards to the remote endpoint with Basic Auth
- The collector has memory limiting (80% threshold) and health checks (port 13133)

When `otelCollector.enabled=false`:
- Agents send data directly to `https://{clientName}.{endpointDomain}:{endpointPort}`
- Each agent authenticates with Basic Auth headers
- No collector deployment, service, or configmap is created

### ApexData Agent

| Parameter | Description | Default |
|-----------|-------------|---------|
| `agent.enabled` | Enable Agent | `true` |
| `agent.replicas` | Number of replicas | `1` |
| `agent.image.repository` | Image repository | `docker.io/apexdata/apexdata-agent` |
| `agent.image.tag` | Image tag | `latest` |
| `agent.resourcesList` | K8s resources to collect | (see values.yaml) |
| `agent.resources.limits.cpu` | CPU limit | `500m` |
| `agent.resources.limits.memory` | Memory limit | `1Gi` |
| `agent.resources.requests.cpu` | CPU request | `100m` |
| `agent.resources.requests.memory` | Memory request | `256Mi` |
| `agent.nodeSelector` | Node selector | `{}` |
| `agent.tolerations` | Tolerations | `[]` |
| `agent.affinity` | Affinity rules | `{}` |

### Unscheduled Pods Tracker

| Parameter | Description | Default |
|-----------|-------------|---------|
| `unscheduledPods.enabled` | Enable tracker | `true` |
| `unscheduledPods.replicas` | Number of replicas | `1` |

### Shard DaemonSet

| Parameter | Description | Default |
|-----------|-------------|---------|
| `shard.enabled` | Enable Shard DaemonSet | `true` |
| `shard.updateStrategy.type` | Update strategy | `RollingUpdate` |
| `shard.tolerations` | Tolerations (use `[{operator: Exists}]` for all nodes) | `[]` |

### RBAC & ServiceAccount

| Parameter | Description | Default |
|-----------|-------------|---------|
| `serviceAccount.create` | Create ServiceAccount | `true` |
| `serviceAccount.name` | ServiceAccount name | (auto-generated) |
| `serviceAccount.annotations` | SA annotations (IRSA, Workload Identity) | `{}` |
| `serviceAccount.automountServiceAccountToken` | Auto-mount token | `true` |
| `rbac.create` | Create ClusterRole/ClusterRoleBinding | `true` |

## Custom Metrics / Shared Credentials

The chart creates a Secret with OTLP credentials that any app in the namespace can use to send metrics directly to the remote ApexData endpoint:

```
Secret: {release}-apexdata-agent-otlp-credentials
```

This Secret contains:
- `OTEL_EXPORTER_OTLP_ENDPOINT` — the remote collector URL
- `OTEL_EXPORTER_OTLP_HEADERS` — Basic Auth header
- `OTEL_EXPORTER_OTLP_PROTOCOL` — `grpc`

To use it in any Deployment:

```yaml
spec:
  containers:
    - name: my-app
      env:
        - name: OTEL_SERVICE_NAME
          value: "my-app"
      envFrom:
        - secretRef:
            name: apexdata-agent-otlp-credentials  # adjust if release name differs
```

See [`custom-metrics/`](../../custom-metrics/) for full examples including Go and Python code.

## Components

| Component | Type | Description |
|-----------|------|-------------|
| `*-agent` | Deployment | Main agent for cluster-wide K8s resource collection (non-privileged) |
| `*-unscheduled-pods` | Deployment | Tracks unscheduled pods |
| `*-shard` | DaemonSet | Node-level metrics collection via eBPF (privileged, runs on every node) |
| `*-otel-collector` | Deployment | OpenTelemetry Collector for buffering and forwarding (only when `otelCollector.enabled=true`) |

### Data Flow

**Direct mode** (`otelCollector.enabled=false`):
```
agent ─────────────┐
unscheduled-pods ──┼──(OTLP/gRPC + TLS + Basic Auth)──> Remote ApexData Collector
shard (per node) ──┘
```

**Collector mode** (`otelCollector.enabled=true`):
```
agent ─────────────┐
unscheduled-pods ──┼──(OTLP/gRPC, no auth)──> OTel Collector ──(OTLP/gRPC + TLS + Auth)──> Remote
shard (per node) ──┘                          (in-cluster)
```

**Custom collector (advanced)**:
```
agent ─────────────┐                                         ┌──> ApexData Remote (Auth)
unscheduled-pods ──┼──(OTLP/gRPC, no auth)──> Your Collector ├──> VictoriaMetrics (local)
shard (per node) ──┘                                         └──> Other backends
```

## Upgrading

```bash
helm upgrade apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai \
  -f my-values.yaml
```

## Uninstallation

```bash
helm uninstall apexdata-agent --namespace apexdata-ai

# Optionally delete namespace
kubectl delete namespace apexdata-ai
```

## Verification

```bash
# Check all resources
kubectl get all -n apexdata-ai

# Check pods status
kubectl get pods -n apexdata-ai -w

# Check agent logs
kubectl logs -n apexdata-ai -l app.kubernetes.io/component=agent -f

# Check shard logs (on specific node)
kubectl logs -n apexdata-ai -l app.kubernetes.io/component=shard --field-selector spec.nodeName=<node-name>

# Check OTel collector logs (only in collector mode)
kubectl logs -n apexdata-ai -l app.kubernetes.io/component=otel-collector -f

# Check services (collector service only exists in collector mode)
kubectl get svc -n apexdata-ai
```

## Troubleshooting

### Pods not starting

```bash
# Check events
kubectl describe pod -n apexdata-ai <pod-name>

# Check resource availability
kubectl top nodes

# Check PVC if any
kubectl get pvc -n apexdata-ai
```

### Authentication errors

In **direct mode**, check agent logs for auth errors:
```bash
kubectl logs -n apexdata-ai -l app.kubernetes.io/component=agent | grep -i "auth\|401\|403"
```

In **collector mode**, check collector logs (only the collector authenticates):
```bash
kubectl logs -n apexdata-ai -l app.kubernetes.io/component=otel-collector | grep -i "auth\|401\|403"
```

Verify credentials:
```bash
# The credentials are Base64(clientName:password)
echo -n 'your-client-name:your-password' | base64
```

### Network issues

```bash
# Check service endpoints
kubectl get endpoints -n apexdata-ai

# In collector mode, test connectivity from agent to collector
kubectl exec -n apexdata-ai -it deploy/apexdata-agent-agent -- nc -zv apexdata-agent-otel-collector 4317

# Check network policies
kubectl get networkpolicies -n apexdata-ai
```

### Shard not collecting on some nodes

```bash
# Check DaemonSet status
kubectl get daemonset -n apexdata-ai

# Check if tolerations are set for special nodes
kubectl describe node <node-name> | grep -A5 Taints
```

If some nodes have taints, add tolerations in values:
```yaml
shard:
  tolerations:
    - operator: Exists  # run on all nodes
```

## Support

For issues and questions:
- Documentation: https://github.com/apexdataai/apexdata-agent-public
- Support: https://apexdata.ai
