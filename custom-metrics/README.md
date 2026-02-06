# Custom Metrics — OTLP Export via ApexData Agent

Send custom application metrics to ApexData alongside the monitoring agent. Custom metrics use the same OTel Collector and authentication that the agent Helm chart provides.

## How It Fits Together

```
┌──────────────────────────────────┐
│         Helm chart               │
│     (apexdata-agent)             │
│                                  │
│  Agent ──┐                       │
│  Shard ──┼──► OTel Collector ──► ApexData (remote)
│  Unsched ┘    (optional)         │
│                                  │
│  Your App ───────────────────────┘
│  (custom metrics)
└──────────────────────────────────┘
```

Custom metrics integrate with the agent in two ways:

| Mode | How | Auth |
|------|-----|------|
| **With collector** (`otelCollector.enabled=true`) | App sends to the shared in-cluster collector | No auth needed for app |
| **Without collector** (`otelCollector.enabled=false`) | App sends directly to remote endpoint | App needs credentials |

## Quick Start

```bash
# Set your endpoint and auth (or use a local collector)
export OTEL_EXPORTER_OTLP_ENDPOINT=localhost:4317
export OTEL_EXPORTER_OTLP_INSECURE=true
export OTEL_SERVICE_NAME=my-app

go run send_metrics.go
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector endpoint (host:port) | `localhost:4317` |
| `OTEL_EXPORTER_OTLP_HEADERS` | Auth headers (`key=value` format) | _(empty)_ |
| `OTEL_EXPORTER_OTLP_INSECURE` | Disable TLS (`true` for local collector) | `false` |
| `OTEL_SERVICE_NAME` | Service name for metrics | `custom-metrics-go-demo` |

## Supported Metric Types

| Type | Standard API | Producer API | Use Case |
|------|--------------|--------------|----------|
| **Counter** | No | **Yes** | Request counts, error totals |
| **Histogram** | No | **Yes** | Latency distribution |
| **UpDownCounter** | **Yes** | Yes | Active connections, queue depth |
| **Observable Gauge** | **Yes** | Yes | CPU, memory, temperature |

### Why Two APIs?

The ApexData collector processes metrics differently based on how they're sent:

- **Standard OTel API** (`meter.Int64Counter()`) — Counter and Histogram are filtered
- **Producer API** (`metricdata.Sum`, `metricdata.Histogram`) — All types work (same approach as apexdata-agent)

## Usage Patterns

### Counter and Histogram (via Producer)

For Counter and Histogram, use the `CustomMetricsProducer` pattern:

```go
type CustomMetricsProducer struct {
    startTime    time.Time
    requestCount atomic.Int64
}

func (p *CustomMetricsProducer) Produce(ctx context.Context) ([]metricdata.ScopeMetrics, error) {
    return []metricdata.ScopeMetrics{{
        Scope: instrumentation.Scope{Name: "my-app"},
        Metrics: []metricdata.Metrics{{
            Name: "my_requests_total",
            Data: metricdata.Sum[float64]{
                Temporality: metricdata.CumulativeTemporality,
                IsMonotonic: true,
                DataPoints: []metricdata.DataPoint[float64]{{
                    StartTime: p.startTime,
                    Time:      time.Now(),
                    Value:     float64(p.requestCount.Load()),
                }},
            },
        }},
    }}, nil
}

// Register producer
provider := sdkmetric.NewMeterProvider(
    sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exporter,
        sdkmetric.WithProducer(&CustomMetricsProducer{}),
    )),
)
```

### UpDownCounter and Gauge (via Standard API)

These work with the standard OTel API:

```go
meter := provider.Meter("my-app")

// UpDownCounter
connections, _ := meter.Int64UpDownCounter("custom.connections.active")
connections.Add(ctx, 1)   // +1
connections.Add(ctx, -1)  // -1

// Observable Gauge
meter.Float64ObservableGauge("custom.cpu.usage",
    otelmetric.WithFloat64Callback(func(_ context.Context, o otelmetric.Float64Observer) error {
        o.Observe(getCPUUsage())
        return nil
    }),
)
```

## Metric Naming

Use underscores for Counter/Histogram (Producer), dots for Gauge/UpDownCounter (Standard):

```
# Producer metrics (Counter, Histogram)
custom_http_requests_total
custom_http_duration_seconds

# Standard metrics (Gauge, UpDownCounter)
custom.http.connections.active
custom.system.cpu.usage
```

Dots are automatically converted to underscores on the backend.

## Kubernetes Deployment

### Build Docker Image

```bash
docker build -t YOUR_REGISTRY/custom-metrics:latest .
docker push YOUR_REGISTRY/custom-metrics:latest
```

### Option A: Shared Collector (recommended)

Deploy the agent with `otelCollector.enabled=true`. Your app sends to the same collector — no credentials needed in the app.

```
Your App (no auth) ──gRPC──► OTel Collector ──TLS+Auth──► ApexData
                              (Helm-managed)               (remote)
```

**1. Deploy the agent with collector:**

```bash
helm install apexdata helm/apexdata-agent \
  --set apexdata.clientName=YOUR_CLIENT \
  --set apexdata.password=YOUR_PASSWORD \
  --set apexdata.clusterName=YOUR_CLUSTER \
  --set otelCollector.enabled=true
```

**2. Deploy your app:**

```bash
# Update the image in k8s/app-local-collector.yaml, then:
kubectl apply -f k8s/app-local-collector.yaml
```

Key env vars for the app:
```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "apexdata-apexdata-agent-otel-collector:4317"    # Helm service name
  - name: OTEL_EXPORTER_OTLP_INSECURE
    value: "true"                                           # no TLS inside cluster
  - name: OTEL_SERVICE_NAME
    value: "my-app"
```

> The collector service name follows Helm convention: `{RELEASE}-apexdata-agent-otel-collector`. If your release name is different, adjust accordingly.

**3. Verify:**

```bash
# Check collector receives metrics from both agent and your app
kubectl -n apexdata-ai logs deploy/apexdata-apexdata-agent-otel-collector -f
```

### Option B: Direct to Remote (no collector)

App sends directly to the remote collector. Each app needs its own credentials.

```
Your App (TLS + Basic Auth) ──gRPC──► ApexData (remote)
```

**1. Create a secret with credentials:**

```bash
kubectl -n apexdata-ai create secret generic custom-metrics-credentials \
  --from-literal=OTEL_EXPORTER_OTLP_ENDPOINT="YOUR_CLIENT.collector.eu.apexdata.ai:444" \
  --from-literal=OTEL_EXPORTER_OTLP_HEADERS="authorization=Basic YOUR_BASE64_TOKEN"
```

**2. Deploy your app:**

```bash
kubectl apply -f k8s/app-remote-collector.yaml
```

### When to Use Which

| | Shared Collector | Direct to Remote |
|---|---|---|
| **Auth management** | One place (collector) | Every app needs credentials |
| **Network** | In-cluster gRPC (fast) | TLS over internet per app |
| **Reliability** | Collector buffers/retries | App must handle failures |
| **Flexibility** | Can fan-out to multiple backends | Single destination |
| **Complexity** | Already deployed with agent | Simpler for standalone apps |

**Recommendation:** Use the shared collector for production. Direct-to-remote is fine for dev/testing.

### Adding to an Existing App

You don't need `send_metrics.go` as a standalone deployment. Copy the metric sending logic into your own app:

```yaml
# Add these env vars to any Deployment in the same namespace
env:
  # Option A: shared collector (otelCollector.enabled=true)
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "apexdata-apexdata-agent-otel-collector:4317"
  - name: OTEL_EXPORTER_OTLP_INSECURE
    value: "true"
  - name: OTEL_SERVICE_NAME
    value: "my-app"
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your Application                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────┐    ┌──────────────────────────────┐   │
│  │   Standard API      │    │     Producer API             │   │
│  │                     │    │                              │   │
│  │  meter.Int64        │    │  metricdata.Sum[float64]     │   │
│  │  UpDownCounter()    │    │  metricdata.Histogram        │   │
│  │                     │    │                              │   │
│  │  meter.Observable   │    │  Implement:                  │   │
│  │  Gauge()            │    │  Produce(ctx) []ScopeMetrics │   │
│  │                     │    │                              │   │
│  │  OK: Gauge          │    │  OK: Counter                 │   │
│  │  OK: UpDownCounter  │    │  OK: Histogram               │   │
│  │  NO: Counter        │    │  OK: Gauge                   │   │
│  │  NO: Histogram      │    │  OK: UpDownCounter           │   │
│  └─────────────────────┘    └──────────────────────────────┘   │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │                    MeterProvider                          │ │
│  │   PeriodicReader(exporter, WithProducer(producer))        │ │
│  └───────────────────────────────────────────────────────────┘ │
│                              │                                  │
└──────────────────────────────│──────────────────────────────────┘
                               │ OTLP gRPC
                               ▼
              ┌────────────────────────────────┐
              │  (A) Shared OTel Collector     │
              │  apexdata-agent-otel-collector │
              │  :4317 (no auth)               │
              │           │                    │
              │           ▼ TLS + Basic Auth   │
              └────────────────────────────────┘
                          │
              ┌───────────┴──────────────────┐
              │  (B) Direct to remote        │
              │  YOUR_CLIENT.collector       │
              │  .eu.apexdata.ai:444         │
              │  TLS + Basic Auth            │
              └──────────────────────────────┘
```

## Files

| File | Description |
|------|-------------|
| `send_metrics.go` | Complete Go example with all metric types (Counter, Histogram, UpDownCounter, Gauge) |
| `send_metrics_debug.go` | Simplified debug/testing version |
| `send_metrics.py` | Python example with all metric types |
| `Dockerfile` | Multi-stage build for Go example |
| `k8s/app-local-collector.yaml` | App deployment using shared Helm collector (no auth) |
| `k8s/app-remote-collector.yaml` | App deployment sending directly to remote (TLS + Basic Auth) |

## Troubleshooting

### Counter/Histogram not appearing

Use the Producer API (see examples above). Standard API doesn't work for these types with ApexData.

### Connection errors

```bash
# Check the collector is running
kubectl -n apexdata-ai get pods -l app.kubernetes.io/component=otel-collector

# Check collector logs
kubectl -n apexdata-ai logs -l app.kubernetes.io/component=otel-collector -f

# Verify your app can reach the collector
kubectl -n apexdata-ai exec deploy/custom-metrics-demo -- \
  nc -zv apexdata-apexdata-agent-otel-collector 4317
```

### Verify token (direct mode)

```bash
# Decode Basic auth to check credentials
echo "YOUR_BASE64_TOKEN" | base64 -d
```
