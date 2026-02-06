// Debug: send Counter as metricdata.Sum via Producer (like agent does)
//
// Usage:
//   export OTEL_EXPORTER_OTLP_ENDPOINT=your-collector:444
//   export OTEL_EXPORTER_OTLP_HEADERS="authorization=Basic YOUR_TOKEN"
//   go run send_metrics_debug.go
package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
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

// customProducer produces metrics like agent's processPrometheusMetricFamily
type customProducer struct {
	counterValue *atomic.Int64
	startTime    time.Time
}

func (p *customProducer) Produce(ctx context.Context) ([]metricdata.ScopeMetrics, error) {
	now := time.Now()
	value := float64(p.counterValue.Load())

	// Create Counter metric exactly like agent does in processPrometheusMetricFamily
	scopeMetrics := []metricdata.ScopeMetrics{
		{
			Scope: instrumentation.Scope{
				Name:    "custom-producer",
				Version: "1.0.0",
			},
			Metrics: []metricdata.Metrics{
				{
					Name:        "custom_producer_requests_total",
					Description: "Counter via Producer (like agent)",
					Unit:        "1",
					Data: metricdata.Sum[float64]{
						Temporality: metricdata.CumulativeTemporality,
						IsMonotonic: true,
						DataPoints: []metricdata.DataPoint[float64]{
							{
								StartTime:  p.startTime,
								Time:       now,
								Value:      value,
								Attributes: attribute.NewSet(
									attribute.String("method", "GET"),
									attribute.String("status", "200"),
								),
							},
						},
					},
				},
				{
					Name:        "custom_producer_duration_seconds",
					Description: "Histogram via Producer (like agent)",
					Unit:        "s",
					Data: metricdata.Histogram[float64]{
						Temporality: metricdata.CumulativeTemporality,
						DataPoints: []metricdata.HistogramDataPoint[float64]{
							{
								StartTime:    p.startTime,
								Time:         now,
								Count:        uint64(value),
								Sum:          value * 0.15, // avg 150ms
								Min:          metricdata.NewExtrema(0.05),
								Max:          metricdata.NewExtrema(0.5),
								Bounds:       []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
								BucketCounts: []uint64{0, 0, 0, uint64(value / 4), uint64(value / 2), uint64(value / 4), 0, 0, 0, 0, 0, 0},
								Attributes:   attribute.NewSet(attribute.String("method", "GET")),
							},
						},
					},
				},
				// Reference: Gauge (known to work)
				{
					Name:        "custom_producer_gauge_value",
					Description: "Gauge via Producer",
					Unit:        "1",
					Data: metricdata.Gauge[float64]{
						DataPoints: []metricdata.DataPoint[float64]{
							{
								Time:       now,
								Value:      42.5,
								Attributes: attribute.NewSet(attribute.String("source", "producer")),
							},
						},
					},
				},
			},
		},
	}

	fmt.Printf("  Producer: counter=%d, histogram_count=%d, gauge=42.5\n", int(value), int(value))
	return scopeMetrics, nil
}

func main() {
	fmt.Println("=== Testing Counter via Producer (like agent) ===\n")

	ctx := context.Background()

	endpoint := getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317")
	headers := parseHeaders(os.Getenv("OTEL_EXPORTER_OTLP_HEADERS"))

	fmt.Printf("Endpoint: %s\n", endpoint)
	fmt.Printf("Headers:  %d configured\n\n", len(headers))

	otlpExp, err := otlpmetricgrpc.New(ctx,
		otlpmetricgrpc.WithEndpoint(endpoint),
		otlpmetricgrpc.WithHeaders(headers),
		otlpmetricgrpc.WithTLSCredentials(credentials.NewClientTLSFromCert(nil, "")),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create OTLP exporter: %v\n", err)
		os.Exit(1)
	}

	hostname, _ := os.Hostname()
	res, _ := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes(
			"",
			semconv.ServiceName("custom-metrics-producer"),
			semconv.ServiceVersion("1.0.0"),
			semconv.HostName(hostname),
			attribute.String("deployment.environment", "demo"),
		),
	)

	counterValue := &atomic.Int64{}
	producer := &customProducer{
		counterValue: counterValue,
		startTime:    time.Now(),
	}

	provider := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(otlpExp,
			sdkmetric.WithInterval(5*time.Second),
			sdkmetric.WithProducer(producer), // Use producer like agent
		)),
	)
	defer func() {
		fmt.Println("\nShutting down...")
		provider.Shutdown(context.Background())
	}()

	fmt.Println("Metrics being sent via Producer:")
	fmt.Println("  custom_producer_requests_total   (Sum[float64] - like agent)")
	fmt.Println("  custom_producer_duration_seconds (Histogram[float64] - like agent)")
	fmt.Println("  custom_producer_gauge_value      (Gauge - reference)")
	fmt.Println()

	for i := 0; i < 10; i++ {
		counterValue.Add(1)
		time.Sleep(1 * time.Second)
	}

	fmt.Println("\nWaiting for exports (20s)...")
	time.Sleep(20 * time.Second)
	fmt.Println("Done!")
}
