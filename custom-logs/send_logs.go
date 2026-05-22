// Send custom OTLP logs to the ApexData collector.
//
// Uses the slog bridge (go.opentelemetry.io/contrib/bridges/otelslog): standard
// log/slog calls are shipped to the collector as OTLP LogRecords. Each request is
// handled inside a trace span, so the log records carry TraceId/SpanId.
//
// Usage:
//
//	go run send_logs.go
//
// Environment variables:
//
//	OTEL_EXPORTER_OTLP_ENDPOINT  - Collector endpoint (default: localhost:4317)
//	OTEL_EXPORTER_OTLP_HEADERS   - Auth headers (default: none)
//	OTEL_SERVICE_NAME            - Service name (default: custom-logs-go-demo)
//	OTEL_EXPORTER_OTLP_INSECURE  - "true" disables TLS (default: false)
package main

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand"
	"os"
	"os/signal"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	otellog "go.opentelemetry.io/otel/sdk/log"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
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

func main() {
	endpoint := getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317")
	headersStr := getEnv("OTEL_EXPORTER_OTLP_HEADERS", "")
	serviceName := getEnv("OTEL_SERVICE_NAME", "custom-logs-go-demo")
	headers := parseHeaders(headersStr)

	// otlploggrpc wants host:port — strip any scheme.
	endpoint = strings.TrimPrefix(endpoint, "https://")
	endpoint = strings.TrimPrefix(endpoint, "http://")

	fmt.Printf("=== Custom Logs Sender (Go/gRPC) ===\n")
	fmt.Printf("Endpoint: %s\n", endpoint)
	fmt.Printf("Service:  %s\n", serviceName)
	fmt.Printf("Headers:  %d configured\n\n", len(headers))

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	opts := []otlploggrpc.Option{
		otlploggrpc.WithEndpoint(endpoint),
		otlploggrpc.WithHeaders(headers),
	}
	if getEnv("OTEL_EXPORTER_OTLP_INSECURE", "false") == "true" {
		opts = append(opts, otlploggrpc.WithInsecure())
	} else {
		opts = append(opts, otlploggrpc.WithTLSCredentials(credentials.NewClientTLSFromCert(nil, "")))
	}

	exporter, err := otlploggrpc.New(ctx, opts...)
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

	provider := otellog.NewLoggerProvider(
		otellog.WithResource(res),
		otellog.WithProcessor(otellog.NewBatchProcessor(exporter)),
	)
	defer func() {
		fmt.Println("\nShutting down...")
		provider.Shutdown(context.Background())
		fmt.Println("Done!")
	}()

	// slog bridge: standard log/slog calls become OTLP LogRecords.
	logger := otelslog.NewLogger("custom-logs", otelslog.WithLoggerProvider(provider))

	// Trace provider only mints span contexts so log records carry TraceId/SpanId.
	// Spans themselves are not exported (no span exporter) — that is intentional.
	tp := sdktrace.NewTracerProvider(sdktrace.WithResource(res))
	defer tp.Shutdown(context.Background())
	tracer := tp.Tracer("custom-logs")

	fmt.Println("Sending logs every 2 seconds... (Ctrl+C to stop)")
	fmt.Println("Severities: INFO (normal), WARN (slow), ERROR (failed)")
	fmt.Println()

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	routes := []string{"/api/users", "/api/orders", "/api/checkout", "/healthz"}
	iteration := 0

	for {
		select {
		case <-ctx.Done():
			fmt.Printf("\nStopping after %d iterations...\n", iteration)
			return
		case <-ticker.C:
			iteration++
			route := routes[rand.Intn(len(routes))]
			durationMs := rand.Intn(500)
			status := 200

			// Each request is handled inside a span -> logs carry TraceId/SpanId.
			reqCtx, span := tracer.Start(ctx, "handle_request")

			switch {
			case rand.Float64() < 0.1:
				status = 500
				logger.ErrorContext(reqCtx, "request failed",
					slog.String("http.method", "GET"),
					slog.String("http.route", route),
					slog.Int("http.status_code", status),
					slog.Int("duration_ms", durationMs),
					slog.String("error", "upstream timeout"),
				)
			case durationMs > 350:
				logger.WarnContext(reqCtx, "slow request",
					slog.String("http.method", "GET"),
					slog.String("http.route", route),
					slog.Int("http.status_code", status),
					slog.Int("duration_ms", durationMs),
				)
			default:
				logger.InfoContext(reqCtx, "request handled",
					slog.String("http.method", "GET"),
					slog.String("http.route", route),
					slog.Int("http.status_code", status),
					slog.Int("duration_ms", durationMs),
				)
			}

			span.End()

			if iteration%10 == 0 {
				fmt.Printf("  [%d] logs sent\n", iteration)
			}
		}
	}
}
