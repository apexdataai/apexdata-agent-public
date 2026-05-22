// Send custom OTLP logs to the ApexData collector (JavaScript example).
//
// Uses the raw @opentelemetry/sdk-logs API: logger.emit() ships records as OTLP
// LogRecords. Each request is emitted inside a trace span, so records carry
// TraceId/SpanId. Apps already using Winston can instead bridge via
// @opentelemetry/winston-transport (see README).
//
// Usage:
//   npm install && npm start
//
// Environment variables:
//   OTEL_EXPORTER_OTLP_ENDPOINT  - Collector endpoint (default: localhost:4317)
//   OTEL_EXPORTER_OTLP_HEADERS   - Auth headers (default: none)
//   OTEL_SERVICE_NAME            - Service name (default: custom-logs-js-demo)
//   OTEL_EXPORTER_OTLP_INSECURE  - "true" disables TLS (default: false)

'use strict';

const os = require('os');
const grpc = require('@grpc/grpc-js');
const { context, trace, propagation } = require('@opentelemetry/api');
const { AsyncLocalStorageContextManager } = require('@opentelemetry/context-async-hooks');
const { SeverityNumber } = require('@opentelemetry/api-logs');
const { LoggerProvider, BatchLogRecordProcessor } = require('@opentelemetry/sdk-logs');
const { OTLPLogExporter } = require('@opentelemetry/exporter-logs-otlp-grpc');
const { resourceFromAttributes } = require('@opentelemetry/resources');
const { BasicTracerProvider, AlwaysOnSampler } = require('@opentelemetry/sdk-trace-base');
const {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} = require('@opentelemetry/semantic-conventions');

// Register the async-local-storage context manager so that context.with() propagates
// span context to log records (TraceId/SpanId correlation).
context.setGlobalContextManager(new AsyncLocalStorageContextManager());

function getEnv(key, fallback) {
  const v = process.env[key];
  return v !== undefined && v !== '' ? v : fallback;
}

function buildMetadata(headersStr) {
  const metadata = new grpc.Metadata();
  for (const pair of headersStr.split(',')) {
    const trimmed = pair.trim();
    const idx = trimmed.indexOf('=');
    if (idx > 0) {
      // gRPC metadata keys must be lowercase.
      const key = trimmed.slice(0, idx).trim().toLowerCase();
      const value = trimmed.slice(idx + 1).trim();
      if (key && value) metadata.set(key, value);
    }
  }
  return metadata;
}

function main() {
  let endpoint = getEnv('OTEL_EXPORTER_OTLP_ENDPOINT', 'localhost:4317');
  const headersStr = getEnv('OTEL_EXPORTER_OTLP_HEADERS', '');
  const serviceName = getEnv('OTEL_SERVICE_NAME', 'custom-logs-js-demo');
  const insecure = getEnv('OTEL_EXPORTER_OTLP_INSECURE', 'false') === 'true';

  // The OTLP gRPC exporter wants a bare host:port — strip any scheme.
  endpoint = endpoint.replace(/^https?:\/\//, '');

  const metadata = buildMetadata(headersStr);

  console.log('=== Custom Logs Sender (JS/gRPC) ===');
  console.log(`Endpoint: ${endpoint}`);
  console.log(`Service:  ${serviceName}`);
  console.log(`Headers:  ${Object.keys(metadata.toJSON()).length} configured\n`);

  const resource = resourceFromAttributes({
    [ATTR_SERVICE_NAME]: serviceName,
    [ATTR_SERVICE_VERSION]: '1.0.0',
    'host.name': os.hostname(),
    'deployment.environment': 'demo',
  });

  const exporter = new OTLPLogExporter({
    url: endpoint,
    metadata,
    credentials: insecure
      ? grpc.credentials.createInsecure()
      : grpc.credentials.createSsl(),
  });

  const loggerProvider = new LoggerProvider({
    resource,
    processors: [new BatchLogRecordProcessor(exporter)],
  });

  // Trace provider only mints span contexts so log records carry TraceId/SpanId.
  // Spans themselves are not exported (no span processor) — that is intentional.
  const tracerProvider = new BasicTracerProvider({
    resource,
    sampler: new AlwaysOnSampler(),
  });
  const tracer = tracerProvider.getTracer('custom-logs');
  const logger = loggerProvider.getLogger('custom-logs', '1.0.0');

  console.log('Sending logs every 2 seconds... (Ctrl+C to stop)');
  console.log('Severities: INFO (normal), WARN (slow), ERROR (failed)\n');

  const routes = ['/api/users', '/api/orders', '/api/checkout', '/healthz'];
  let iteration = 0;

  const timer = setInterval(() => {
    iteration += 1;
    const route = routes[Math.floor(Math.random() * routes.length)];
    const durationMs = Math.floor(Math.random() * 500);
    let status = 200;

    // Emit inside an active span so the log record carries TraceId/SpanId.
    const span = tracer.startSpan('handle_request');
    context.with(trace.setSpan(context.active(), span), () => {
      const roll = Math.random();
      if (roll < 0.1) {
        status = 500;
        logger.emit({
          severityNumber: SeverityNumber.ERROR,
          severityText: 'ERROR',
          body: 'request failed',
          attributes: {
            'http.method': 'GET',
            'http.route': route,
            'http.status_code': status,
            'duration_ms': durationMs,
            'error': 'upstream timeout',
          },
        });
      } else if (durationMs > 350) {
        logger.emit({
          severityNumber: SeverityNumber.WARN,
          severityText: 'WARN',
          body: 'slow request',
          attributes: {
            'http.method': 'GET',
            'http.route': route,
            'http.status_code': status,
            'duration_ms': durationMs,
          },
        });
      } else {
        logger.emit({
          severityNumber: SeverityNumber.INFO,
          severityText: 'INFO',
          body: 'request handled',
          attributes: {
            'http.method': 'GET',
            'http.route': route,
            'http.status_code': status,
            'duration_ms': durationMs,
          },
        });
      }
    });
    span.end();

    if (iteration % 10 === 0) console.log(`  [${iteration}] logs sent`);
  }, 2000);

  const shutdown = async () => {
    clearInterval(timer);
    console.log('\nShutting down...');
    try {
      await loggerProvider.shutdown();
      await tracerProvider.shutdown();
    } catch (err) {
      console.error('shutdown error:', err);
    }
    console.log('Done!');
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main();
