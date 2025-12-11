# ApexData Agent Helm Chart

Helm chart for deploying ApexData Agent and OpenTelemetry Collector to Kubernetes clusters.

## Prerequisites

- Kubernetes 1.20+
- Helm 3.0+
- Cluster admin rights for RBAC resources

## Installation

### Quick Start

```bash
helm install apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai \
  --create-namespace \
  --set apexdata.otelEndpoint="clientname-otel.app.apexdata.ai" \
  --set apexdata.base64Credentials="$(echo -n 'username:password' | base64)" \
  --set apexdata.clusterName="production-cluster"
```

### Using Values File (Recommended)

```bash
# Copy example values
cp helm/apexdata-agent/values.example.yaml my-values.yaml

# Edit with your configuration
# Required: apexdata.otelEndpoint, apexdata.base64Credentials, apexdata.clusterName

# Install
helm install apexdata-agent ./helm/apexdata-agent \
  --namespace apexdata-ai \
  --create-namespace \
  -f my-values.yaml
```

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
| `apexdata.otelEndpoint` | OTel endpoint (without port) | `"clientname-otel.app.apexdata.ai"` |
| `apexdata.base64Credentials` | Base64 encoded username:password | `"dXNlcm5hbWU6cGFzc3dvcmQ="` |
| `apexdata.clusterName` | Cluster identifier | `"production-cluster"` |

### Global Settings

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.namespace` | Namespace for all resources | `apexdata-ai` |
| `global.createNamespace` | Create namespace if not exists | `true` |
| `global.imagePullSecrets` | Image pull secrets for private registries | `[]` |

### OpenTelemetry Collector

| Parameter | Description | Default |
|-----------|-------------|---------|
| `otelCollector.enabled` | Enable OTel Collector | `true` |
| `otelCollector.replicas` | Number of replicas | `1` |
| `otelCollector.image.repository` | Image repository | `otel/opentelemetry-collector-contrib` |
| `otelCollector.image.tag` | Image tag | `0.114.0` |
| `otelCollector.resources.limits.cpu` | CPU limit | `1` |
| `otelCollector.resources.limits.memory` | Memory limit | `2Gi` |
| `otelCollector.nodeSelector` | Node selector | `{}` |
| `otelCollector.tolerations` | Tolerations | `[]` |
| `otelCollector.affinity` | Affinity rules | `{}` |
| `otelCollector.podAnnotations` | Pod annotations | `{}` |
| `otelCollector.podDisruptionBudget.enabled` | Enable PDB | `false` |

### ApexData Agent

| Parameter | Description | Default |
|-----------|-------------|---------|
| `agent.enabled` | Enable Agent | `true` |
| `agent.replicas` | Number of replicas | `1` |
| `agent.resourcesList` | K8s resources to collect | (see values.yaml) |
| `agent.nodeSelector` | Node selector | `{}` |
| `agent.tolerations` | Tolerations | `[]` |
| `agent.affinity` | Affinity rules | `{}` |

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
| `rbac.create` | Create ClusterRole/ClusterRoleBinding | `true` |

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

# Check OTel collector logs
kubectl logs -n apexdata-ai -l app.kubernetes.io/component=otel-collector -f

# Check agent logs
kubectl logs -n apexdata-ai -l app.kubernetes.io/component=agent -f

# Check shard logs (on specific node)
kubectl logs -n apexdata-ai -l app.kubernetes.io/component=shard --field-selector spec.nodeName=<node-name>
```

## Components

| Component | Type | Description |
|-----------|------|-------------|
| `*-otel-collector` | Deployment | OpenTelemetry Collector for forwarding metrics/traces/logs |
| `*-agent` | Deployment | Main agent for cluster-wide resource collection |
| `*-unscheduled-pods` | Deployment | Tracks unscheduled pods |
| `*-shard` | DaemonSet | Node-level metrics collection (eBPF) |

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

```bash
# Verify credentials format
echo -n 'username:password' | base64

# Check OTel collector logs for auth errors
kubectl logs -n apexdata-ai -l app.kubernetes.io/component=otel-collector | grep -i "auth\|401\|403"
```

### Network issues

```bash
# Check service endpoints
kubectl get endpoints -n apexdata-ai

# Test connectivity from agent to collector
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

## Support

For issues and questions:
- Documentation: https://github.com/apexdataai/apexdata-agent-public
- Support: https://apexdata.ai
