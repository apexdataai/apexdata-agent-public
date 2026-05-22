// Send custom OTLP metrics to the ApexData collector (JavaScript example).
//
// Counter and Histogram are emitted via a MetricProducer (the JS equivalent of the
// Go sdkmetric.Producer) — the ApexData collector filters Counter/Histogram sent
// through the standard API, so the producer path is required for them. UpDownCounter
// and ObservableGauge use the standard API.
//
// Usage:
//   npm install && npm start
//
// Environment variables:
//   OTEL_EXPORTER_OTLP_ENDPOINT  - Collector endpoint (default: localhost:4317)
//   OTEL_EXPORTER_OTLP_HEADERS   - Auth headers (default: none)
//   OTEL_SERVICE_NAME            - Service name (default: custom-metrics-js-demo)
//   OTEL_EXPORTER_OTLP_INSECURE  - "true" disables TLS (default: false)

'use strict';

const os = require('os');
const grpc = require('@grpc/grpc-js');
const { ValueType } = require('@opentelemetry/api');
const {
  MeterProvider,
  PeriodicExportingMetricReader,
  DataPointType,
  AggregationTemporality,
} = require('@opentelemetry/sdk-metrics');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-grpc');
const { resourceFromAttributes } = require('@opentelemetry/resources');
const { hrTime } = require('@opentelemetry/core');
const {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} = require('@opentelemetry/semantic-conventions');

function getEnv(key, fallback) {
  const v = process.env[key];
  return v !== undefined && v !== '' ? v : fallback;
}

// Build a grpc.Metadata from a comma-separated "key=value,..." string.
// gRPC metadata keys must be lowercase.
function buildMetadata(headersStr) {
  const metadata = new grpc.Metadata();
  for (const pair of headersStr.split(',')) {
    const trimmed = pair.trim();
    const idx = trimmed.indexOf('=');
    if (idx > 0) {
      const key = trimmed.slice(0, idx).trim().toLowerCase();
      const value = trimmed.slice(idx + 1).trim();
      if (key && value) metadata.set(key, value);
    }
  }
  return metadata;
}

// CustomMetricsProducer hand-builds Counter and Histogram metric data. This is the
// JS equivalent of send_metrics.go's sdkmetric.Producer implementation.
class CustomMetricsProducer {
  constructor(hostName) {
    this._startTime = hrTime();
    this._hostName = hostName;
    this._httpRequests = 0;
    this._httpErrors = 0;
    this._durationSamples = [];
    this._durationBounds = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10];
  }

  addRequest(isError) {
    this._httpRequests += 1;
    if (isError) this._httpErrors += 1;
  }

  recordDuration(seconds) {
    this._durationSamples.push(seconds);
  }

  // Build a SumMetricData (counter). MetricDescriptor fields: name, description, unit,
  // valueType — no `type` field (that is on the internal InstrumentDescriptor only).
  _sum(name, description, value, now) {
    return {
      descriptor: {
        name,
        description,
        unit: '1',
        valueType: ValueType.DOUBLE,
      },
      aggregationTemporality: AggregationTemporality.CUMULATIVE,
      dataPointType: DataPointType.SUM,
      isMonotonic: true,
      dataPoints: [
        {
          startTime: this._startTime,
          endTime: now,
          attributes: { 'host.name': this._hostName },
          value,
        },
      ],
    };
  }

  async collect() {
    const now = hrTime();

    const samples = this._durationSamples;
    this._durationSamples = [];
    const bounds = this._durationBounds;
    const counts = new Array(bounds.length + 1).fill(0);
    let sum = 0;
    let min;
    let max;
    for (const s of samples) {
      sum += s;
      if (min === undefined || s < min) min = s;
      if (max === undefined || s > max) max = s;
      let placed = false;
      for (let i = 0; i < bounds.length; i += 1) {
        if (s <= bounds[i]) {
          counts[i] += 1;
          placed = true;
          break;
        }
      }
      if (!placed) counts[counts.length - 1] += 1;
    }

    // HistogramMetricData: dataPoints hold DataPoint<Histogram> where Histogram =
    // { buckets: { boundaries, counts }, count, sum?, min?, max? }
    const histogram = {
      descriptor: {
        name: 'custom_http_duration_seconds',
        description: 'HTTP request duration distribution',
        unit: 's',
        valueType: ValueType.DOUBLE,
      },
      aggregationTemporality: AggregationTemporality.CUMULATIVE,
      dataPointType: DataPointType.HISTOGRAM,
      dataPoints: [
        {
          startTime: this._startTime,
          endTime: now,
          attributes: { 'host.name': this._hostName },
          value: {
            buckets: { boundaries: bounds, counts },
            count: samples.length,
            sum,
            min,
            max,
          },
        },
      ],
    };

    return {
      resourceMetrics: {
        resource: resourceFromAttributes({}),
        scopeMetrics: [
          {
            scope: { name: 'custom-metrics', version: '1.0.0' },
            metrics: [
              this._sum('custom_http_requests_total', 'Total number of HTTP requests', this._httpRequests, now),
              this._sum('custom_http_errors_total', 'Total number of HTTP errors', this._httpErrors, now),
              histogram,
            ],
          },
        ],
      },
      errors: [],
    };
  }
}

function main() {
  let endpoint = getEnv('OTEL_EXPORTER_OTLP_ENDPOINT', 'localhost:4317');
  const headersStr = getEnv('OTEL_EXPORTER_OTLP_HEADERS', '');
  const serviceName = getEnv('OTEL_SERVICE_NAME', 'custom-metrics-js-demo');
  const insecure = getEnv('OTEL_EXPORTER_OTLP_INSECURE', 'false') === 'true';

  // The OTLP gRPC exporter wants a bare host:port — strip any scheme.
  endpoint = endpoint.replace(/^https?:\/\//, '');

  const metadata = buildMetadata(headersStr);

  console.log('=== Custom Metrics Sender (JS/gRPC) ===');
  console.log(`Endpoint: ${endpoint}`);
  console.log(`Service:  ${serviceName}`);
  console.log(`Headers:  ${Object.keys(metadata.toJSON()).length} configured\n`);

  const hostName = os.hostname();
  const resource = resourceFromAttributes({
    [ATTR_SERVICE_NAME]: serviceName,
    [ATTR_SERVICE_VERSION]: '1.0.0',
    'host.name': hostName,
    'deployment.environment': 'demo',
  });

  // The OTel JS gRPC exporter requires a grpc.Metadata instance (not a plain headers
  // object) and credentials via the `credentials:` option.
  const exporter = new OTLPMetricExporter({
    url: endpoint,
    metadata,
    credentials: insecure
      ? grpc.credentials.createInsecure()
      : grpc.credentials.createSsl(),
  });

  const producer = new CustomMetricsProducer(hostName);

  const reader = new PeriodicExportingMetricReader({
    exporter,
    exportIntervalMillis: 10000,
    metricProducers: [producer],
  });

  const meterProvider = new MeterProvider({ resource, readers: [reader] });
  const meter = meterProvider.getMeter('custom-metrics', '1.0.0');

  const connections = meter.createUpDownCounter('custom.http.connections.active', {
    description: 'Number of active HTTP connections',
    unit: '1',
  });
  meter.createObservableGauge('custom.system.cpu.usage', {
    description: 'Current CPU usage percentage',
    unit: '%',
  }).addCallback((res) => {
    res.observe(Math.random() * 50 + 20, { 'host.name': hostName, cpu: 'total' });
  });
  meter.createObservableGauge('custom.system.memory.used', {
    description: 'Memory used in bytes',
    unit: 'By',
  }).addCallback((res) => {
    res.observe(process.memoryUsage().heapUsed, { 'host.name': hostName });
  });

  console.log('Sending metrics every 10 seconds... (Ctrl+C to stop)');
  console.log('  Counter:   custom_http_requests_total, custom_http_errors_total');
  console.log('  Histogram: custom_http_duration_seconds');
  console.log('  UpDown:    custom.http.connections.active');
  console.log('  Gauge:     custom.system.cpu.usage, custom.system.memory.used\n');

  let iteration = 0;
  let currentConnections = 10;

  const timer = setInterval(() => {
    iteration += 1;
    producer.addRequest(Math.random() < 0.05);
    producer.recordDuration(0.05 + Math.random() * 0.45);
    const delta = Math.floor(Math.random() * 5) - 2;
    currentConnections = Math.max(0, currentConnections + delta);
    connections.add(delta);
    if (iteration % 100 === 0) console.log(`  [${iteration}] metrics recorded`);
  }, 100);

  const shutdown = async () => {
    clearInterval(timer);
    console.log('\nShutting down...');
    try {
      await meterProvider.shutdown();
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
