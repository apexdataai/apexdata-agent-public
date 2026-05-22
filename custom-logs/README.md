# Custom Logs — OTLP Export via ApexData Agent

Send custom application logs to ApexData alongside the monitoring agent. Custom logs use the same OTel Collector and authentication that the agent Helm chart provides.

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
│  (custom logs)
└──────────────────────────────────┘
```

Custom logs integrate with the agent in two ways:

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

go run send_logs.go
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector endpoint (host:port) | `localhost:4317` |
| `OTEL_EXPORTER_OTLP_HEADERS` | Auth headers (`key=value` format) | _(empty)_ |
| `OTEL_EXPORTER_OTLP_INSECURE` | Disable TLS (`true` for local collector) | `false` |
| `OTEL_SERVICE_NAME` | Service name for logs | `custom-logs-go-demo` |

## What a Log Record Carries

A log shipped over OTLP is a structured record, not just a line of text:

| Field | Description | Example |
|-------|-------------|---------|
| **Body** | The log message | `request handled` |
| **SeverityText / SeverityNumber** | Log level | `INFO` / `9` |
| **Timestamp** | When the event happened | `2026-01-01T10:00:00Z` |
| **Attributes** | Per-record structured key/values | `http.route=/api/users` |
| **Resource** | Per-process identity | `service.name`, `host.name` |
| **TraceId / SpanId** | Trace correlation (when emitted in a span) | populated automatically |

## Usage

Logs are sent through the **bridge** from each language's standard logging library — you keep writing logs the normal way, and the bridge ships them as OTLP.

### Go — `log/slog` bridge

```go
provider := otellog.NewLoggerProvider(
    otellog.WithResource(res),
    otellog.WithProcessor(otellog.NewBatchProcessor(exporter)),
)
logger := otelslog.NewLogger("my-app", otelslog.WithLoggerProvider(provider))

logger.Info("request handled",
    slog.String("http.route", "/api/users"),
    slog.Int("http.status_code", 200),
)
```

### Python — `logging` handler

```python
logger_provider = LoggerProvider(resource=resource)
logger_provider.add_log_record_processor(BatchLogRecordProcessor(exporter))
handler = LoggingHandler(level=logging.NOTSET, logger_provider=logger_provider)
logging.getLogger().addHandler(handler)

logging.info("request handled", extra={"http.route": "/api/users", "http.status_code": 200})
```

### Raw API (advanced)

The bridge is built on the OTel Logs API. To emit a record directly — bypassing `slog`/`logging` — call the `Logger` itself:

```go
import otellogapi "go.opentelemetry.io/otel/log"

lg := provider.Logger("my-app")
var rec otellogapi.Record
rec.SetTimestamp(time.Now())
rec.SetSeverity(otellogapi.SeverityInfo)
rec.SetBody(otellogapi.StringValue("request handled"))
rec.AddAttributes(otellogapi.String("http.route", "/api/users"))
lg.Emit(ctx, rec)
```

Use the raw API only when the bridge does not fit; for application logs the bridge is the idiomatic choice.

## Trace Correlation

If a log is emitted while a trace span is active, the bridge stamps the record with the span's `TraceId`/`SpanId`. In Go, pass the span's context (`logger.InfoContext(ctx, ...)`); in Python, log inside a `with tracer.start_as_current_span(...)` block. This lets you jump from a log line to its trace.

## Log Conventions

- **Body** — a short, stable message; put variables in attributes, not the body.
- **Attributes** — dotted lowercase keys (`http.route`, `http.status_code`); follow OTel semantic conventions where one exists.
- **Severity** — use `Error` for failures, `Warn` for degraded behavior, `Info` for normal events; avoid `Debug` at production volume.

## Kubernetes Deployment

### Build Docker Image

```bash
docker build -t YOUR_REGISTRY/custom-logs:latest .
docker push YOUR_REGISTRY/custom-logs:latest
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
# Check the collector receives logs from both the agent and your app
kubectl -n apexdata-ai logs deploy/apexdata-apexdata-agent-otel-collector -f
```

### Option B: Direct to Remote (no collector)

App sends directly to the remote collector using credentials from the Helm-managed Secret.

```
Your App (TLS + Basic Auth) ──gRPC──► ApexData (remote)
```

The apexdata-agent Helm chart automatically creates a Secret named `{release}-apexdata-agent-otlp-credentials` with the endpoint, auth header, and protocol. No manual secret creation is needed.

**1. Deploy your app:**

```bash
# Update the image and secret name in the manifest, then:
kubectl apply -f k8s/app-remote-collector.yaml
```

The manifest uses `envFrom` to inject credentials from the Helm-managed Secret:

```yaml
envFrom:
  - secretRef:
      name: apexdata-agent-otlp-credentials  # adjust if release name differs
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

You don't need `send_logs.go` as a standalone deployment. Copy the log-sending setup into your own app:

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
┌─────────────────────────────────────────────┐
│              Your Application               │
│                                             │
│   log/slog   /   logging                    │  standard logging library
│        │                                    │
│        ▼                                    │
│   otelslog  /  LoggingHandler               │  OTel bridge
│        │                                    │
│        ▼                                    │
│   OTLP gRPC Log Exporter                    │
└────────────────────┬────────────────────────┘
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
| `send_logs.go` | Complete Go example — `slog` bridge, all severities, trace correlation |
| `send_logs.py` | Python example — `logging` handler, all severities, trace correlation |
| `Dockerfile` | Multi-stage build for the Go example |
| `k8s/app-local-collector.yaml` | App deployment using the shared Helm collector (no auth) |
| `k8s/app-remote-collector.yaml` | App deployment sending directly to remote (TLS + Basic Auth) |

## Troubleshooting

### Logs not appearing

```bash
# Check the collector is running
kubectl -n apexdata-ai get pods -l app.kubernetes.io/component=otel-collector

# Check collector logs — it prints received records
kubectl -n apexdata-ai logs -l app.kubernetes.io/component=otel-collector -f
```

Logs may take a few seconds to batch and flush.

### Connection errors

```bash
# Verify your app can reach the collector
kubectl -n apexdata-ai exec deploy/custom-logs-demo -- \
  nc -zv apexdata-apexdata-agent-otel-collector 4317
```

### Header keys must be lowercase

gRPC metadata keys must be lowercase. When setting `OTEL_EXPORTER_OTLP_HEADERS`, use `authorization=...` (lowercase). The Go and Python examples normalize this for you.

### Verify token (direct mode)

```bash
# Decode Basic auth to check credentials
echo "YOUR_BASE64_TOKEN" | base64 -d
```
