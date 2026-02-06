// Send custom OTLP metrics to ApexData collector.
//
// This uses the Producer approach for Counter and Histogram (same as apexdata-agent),
// which is required for these metric types to work with ApexData collector.
//
// Usage:
//   go run send_metrics.go
//
// Environment variables:
//   OTEL_EXPORTER_OTLP_ENDPOINT  - Collector endpoint (default: localhost:4317)
//   OTEL_EXPORTER_OTLP_HEADERS   - Auth headers (default: demo credentials)
//   OTEL_SERVICE_NAME            - Service name (default: custom-metrics-go-demo)

package main

import (
	"context"
	"fmt"
	"math/rand"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	otelmetric "go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/sdk/instrumentation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.21.0"
	"google.golang.org/grpc/credentials"
)

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func parseHeaders(headersStr string) map[string]string {
	headers := make(map[string]string)
	for _, pair := range strings.Split(headersStr, ",") {
		pair = strings.TrimSpace(pair)
		if idx := strings.Index(pair, "="); idx > 0 {
			key := strings.TrimSpace(pair[:idx])
			value := strings.TrimSpace(pair[idx+1:])
			if key != "" && value != "" {
				headers[key] = value
			}
		}
	}
	return headers
}

// ════════════════════════════════════════════════════════════════════════════════
// CustomMetricsProducer - Counter and Histogram support via metricdata
// ════════════════════════════════════════════════════════════════════════════════
//
// ApexData collector requires Counter and Histogram to be sent as metricdata.Sum
// and metricdata.Histogram (like apexdata-agent does), not via meter.Int64Counter().

type CustomMetricsProducer struct {
	startTime time.Time
	hostname  string

	// Counters (thread-safe)
	httpRequests atomic.Int64
	httpErrors   atomic.Int64

	// Histogram data (protected by mutex)
	histogramMu       sync.Mutex
	durationSamples   []float64
	durationBounds    []float64
	lastHistogramTime time.Time
}

func NewCustomMetricsProducer(hostname string) *CustomMetricsProducer {
	return &CustomMetricsProducer{
		startTime:         time.Now(),
		hostname:          hostname,
		durationBounds:    []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
		durationSamples:   make([]float64, 0, 1000),
		lastHistogramTime: time.Now(),
	}
}

// AddRequest increments request counter
func (p *CustomMetricsProducer) AddRequest(isError bool) {
	p.httpRequests.Add(1)
	if isError {
		p.httpErrors.Add(1)
	}
}

// RecordDuration adds a duration sample for histogram
func (p *CustomMetricsProducer) RecordDuration(seconds float64) {
	p.histogramMu.Lock()
	p.durationSamples = append(p.durationSamples, seconds)
	p.histogramMu.Unlock()
}

// Produce implements sdkmetric.Producer interface
func (p *CustomMetricsProducer) Produce(ctx context.Context) ([]metricdata.ScopeMetrics, error) {
	now := time.Now()

	// Get counter values
	totalRequests := float64(p.httpRequests.Load())
	totalErrors := float64(p.httpErrors.Load())

	// Process histogram samples
	p.histogramMu.Lock()
	samples := p.durationSamples
	p.durationSamples = make([]float64, 0, 1000)
	startTime := p.lastHistogramTime
	p.lastHistogramTime = now
	p.histogramMu.Unlock()

	// Calculate histogram buckets
	bucketCounts := make([]uint64, len(p.durationBounds)+1)
	var sum, min, max float64
	if len(samples) > 0 {
		min = samples[0]
		max = samples[0]
		for _, s := range samples {
			sum += s
			if s < min {
				min = s
			}
			if s > max {
				max = s
			}
			placed := false
			for i, bound := range p.durationBounds {
				if s <= bound {
					bucketCounts[i]++
					placed = true
					break
				}
			}
			if !placed {
				bucketCounts[len(p.durationBounds)]++
			}
		}
	}

	return []metricdata.ScopeMetrics{
		{
			Scope: instrumentation.Scope{
				Name:    "custom-metrics",
				Version: "1.0.0",
			},
			Metrics: []metricdata.Metrics{
				// Counter: HTTP requests total
				{
					Name:        "custom_http_requests_total",
					Description: "Total number of HTTP requests",
					Unit:        "1",
					Data: metricdata.Sum[float64]{
						Temporality: metricdata.CumulativeTemporality,
						IsMonotonic: true,
						DataPoints: []metricdata.DataPoint[float64]{
							{
								StartTime:  p.startTime,
								Time:       now,
								Value:      totalRequests,
								Attributes: attribute.NewSet(attribute.String("host.name", p.hostname)),
							},
						},
					},
				},
				// Counter: HTTP errors total
				{
					Name:        "custom_http_errors_total",
					Description: "Total number of HTTP errors",
					Unit:        "1",
					Data: metricdata.Sum[float64]{
						Temporality: metricdata.CumulativeTemporality,
						IsMonotonic: true,
						DataPoints: []metricdata.DataPoint[float64]{
							{
								StartTime:  p.startTime,
								Time:       now,
								Value:      totalErrors,
								Attributes: attribute.NewSet(attribute.String("host.name", p.hostname)),
							},
						},
					},
				},
				// Histogram: Request duration
				{
					Name:        "custom_http_duration_seconds",
					Description: "HTTP request duration distribution",
					Unit:        "s",
					Data: metricdata.Histogram[float64]{
						Temporality: metricdata.CumulativeTemporality,
						DataPoints: []metricdata.HistogramDataPoint[float64]{
							{
								StartTime:    startTime,
								Time:         now,
								Count:        uint64(len(samples)),
								Sum:          sum,
								Min:          metricdata.NewExtrema(min),
								Max:          metricdata.NewExtrema(max),
								Bounds:       p.durationBounds,
								BucketCounts: bucketCounts,
								Attributes:   attribute.NewSet(attribute.String("host.name", p.hostname)),
							},
						},
					},
				},
			},
		},
	}, nil
}

// ════════════════════════════════════════════════════════════════════════════════
// Main
// ════════════════════════════════════════════════════════════════════════════════

func main() {
	endpoint := getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317")
	headersStr := getEnv("OTEL_EXPORTER_OTLP_HEADERS", "")
	serviceName := getEnv("OTEL_SERVICE_NAME", "custom-metrics-go-demo")

	headers := parseHeaders(headersStr)

	fmt.Printf("=== Custom Metrics Sender (Go/gRPC) ===\n")
	fmt.Printf("Endpoint: %s\n", endpoint)
	fmt.Printf("Service:  %s\n", serviceName)
	fmt.Printf("Headers:  %d configured\n\n", len(headers))

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	opts := []otlpmetricgrpc.Option{
		otlpmetricgrpc.WithEndpoint(endpoint),
		otlpmetricgrpc.WithHeaders(headers),
	}
	if getEnv("OTEL_EXPORTER_OTLP_INSECURE", "false") == "true" {
		opts = append(opts, otlpmetricgrpc.WithInsecure())
	} else {
		opts = append(opts, otlpmetricgrpc.WithTLSCredentials(credentials.NewClientTLSFromCert(nil, "")))
	}

	exporter, err := otlpmetricgrpc.New(ctx, opts...)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create exporter: %v\n", err)
		os.Exit(1)
	}

	hostname, _ := os.Hostname()
	res, _ := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes(
			"",
			semconv.ServiceName(serviceName),
			semconv.ServiceVersion("1.0.0"),
			semconv.HostName(hostname),
			attribute.String("deployment.environment", "demo"),
		),
	)

	// Create producer for Counter + Histogram
	producer := NewCustomMetricsProducer(hostname)

	provider := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exporter,
			sdkmetric.WithInterval(10*time.Second),
			sdkmetric.WithProducer(producer),
		)),
	)
	defer func() {
		fmt.Println("\nShutting down...")
		provider.Shutdown(context.Background())
		fmt.Println("Done!")
	}()

	meter := provider.Meter("custom-metrics-demo", otelmetric.WithInstrumentationVersion("1.0.0"))

	// UpDownCounter and Gauge work via standard API
	activeConnections, _ := meter.Int64UpDownCounter("custom.http.connections.active",
		otelmetric.WithDescription("Number of active HTTP connections"),
		otelmetric.WithUnit("1"),
	)

	meter.Float64ObservableGauge("custom.system.cpu.usage",
		otelmetric.WithDescription("Current CPU usage percentage"),
		otelmetric.WithUnit("%"),
		otelmetric.WithFloat64Callback(func(_ context.Context, o otelmetric.Float64Observer) error {
			o.Observe(rand.Float64()*50+20, otelmetric.WithAttributes(
				attribute.String("host.name", hostname),
				attribute.String("cpu", "total"),
			))
			return nil
		}),
	)

	meter.Int64ObservableGauge("custom.system.memory.used",
		otelmetric.WithDescription("Memory used in bytes"),
		otelmetric.WithUnit("By"),
		otelmetric.WithInt64Callback(func(_ context.Context, o otelmetric.Int64Observer) error {
			var m runtime.MemStats
			runtime.ReadMemStats(&m)
			o.Observe(int64(m.Alloc), otelmetric.WithAttributes(
				attribute.String("host.name", hostname),
			))
			return nil
		}),
	)

	fmt.Println("Sending metrics every 10 seconds... (Ctrl+C to stop)\n")
	fmt.Println("Metrics (all types work!):")
	fmt.Println("  Counter:    custom_http_requests_total, custom_http_errors_total")
	fmt.Println("  Histogram:  custom_http_duration_seconds")
	fmt.Println("  UpDown:     custom.http.connections.active")
	fmt.Println("  Gauge:      custom.system.cpu.usage, custom.system.memory.used")
	fmt.Println()

	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	iteration := 0
	currentConnections := int64(10)

	for {
		select {
		case <-ctx.Done():
			fmt.Printf("\nStopping after %d iterations...\n", iteration)
			return
		case <-ticker.C:
			iteration++

			// Add request (5% error rate)
			producer.AddRequest(rand.Float64() < 0.05)
			producer.RecordDuration(0.05 + rand.Float64()*0.45)

			// Connection changes
			delta := int64(rand.Intn(5) - 2)
			currentConnections += delta
			if currentConnections < 0 {
				currentConnections = 0
			}
			activeConnections.Add(ctx, delta)

			if iteration%100 == 0 {
				fmt.Printf("  [%d] requests=%d errors=%d connections=%d\n",
					iteration, producer.httpRequests.Load(), producer.httpErrors.Load(), currentConnections)
			}
		}
	}
}
