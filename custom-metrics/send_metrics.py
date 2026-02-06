#!/usr/bin/env python3
"""
Send custom OTLP metrics to ApexData collector using Producer approach.

This uses the same approach as apexdata-agent for Counter and Histogram,
which is required for these metric types to work with ApexData collector.

Usage:
    export OTEL_EXPORTER_OTLP_ENDPOINT=your-collector:444
    export OTEL_EXPORTER_OTLP_HEADERS="authorization=Basic YOUR_TOKEN"
    pip install opentelemetry-sdk opentelemetry-exporter-otlp-proto-grpc
    python send_metrics.py

Environment variables:
    OTEL_EXPORTER_OTLP_ENDPOINT  - Collector endpoint (default: localhost:4317)
    OTEL_EXPORTER_OTLP_HEADERS   - Auth headers (key=value format)
    OTEL_SERVICE_NAME            - Service name (default: custom-metrics-python)
"""

import os
import time
import random
import platform
import threading
from dataclasses import dataclass, field
from typing import Iterable

from opentelemetry import metrics
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import (
    MetricReader,
    PeriodicExportingMetricReader,
    MetricsData,
    Metric,
    Sum,
    Histogram,
    Gauge,
    NumberDataPoint,
    HistogramDataPoint,
    AggregationTemporality,
    ResourceMetrics,
    ScopeMetrics,
)
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.util.instrumentation import InstrumentationScope

# ════════════════════════════════════════════════════════════════════════════════
# Configuration
# ════════════════════════════════════════════════════════════════════════════════

ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317")
HEADERS = os.getenv("OTEL_EXPORTER_OTLP_HEADERS", "")
SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "custom-metrics-python")


def parse_headers(headers_str: str) -> list[tuple[str, str]]:
    """Parse 'key=value,key=value' format into list of tuples."""
    result = []
    for pair in headers_str.split(","):
        pair = pair.strip()
        if "=" in pair:
            key, value = pair.split("=", 1)
            result.append((key.strip(), value.strip()))
    return result


# ════════════════════════════════════════════════════════════════════════════════
# Custom Metrics Producer
# ════════════════════════════════════════════════════════════════════════════════


@dataclass
class CustomMetricsState:
    """Thread-safe state for custom metrics."""

    start_time_ns: int = field(default_factory=lambda: time.time_ns())
    hostname: str = field(default_factory=platform.node)

    # Counter values
    _http_requests: int = 0
    _http_errors: int = 0
    _lock: threading.Lock = field(default_factory=threading.Lock)

    # Histogram samples
    _duration_samples: list = field(default_factory=list)
    _duration_bounds: tuple = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10)

    def add_request(self, is_error: bool = False):
        with self._lock:
            self._http_requests += 1
            if is_error:
                self._http_errors += 1

    def record_duration(self, seconds: float):
        with self._lock:
            self._duration_samples.append(seconds)

    def get_and_reset_histogram(self) -> tuple:
        """Returns (samples, bounds) and resets samples."""
        with self._lock:
            samples = self._duration_samples.copy()
            self._duration_samples.clear()
            return samples, self._duration_bounds

    @property
    def http_requests(self) -> int:
        with self._lock:
            return self._http_requests

    @property
    def http_errors(self) -> int:
        with self._lock:
            return self._http_errors


def create_metrics_data(state: CustomMetricsState, resource: Resource) -> MetricsData:
    """Create MetricsData with Counter and Histogram using Producer approach."""

    now_ns = time.time_ns()
    scope = InstrumentationScope(name="custom-metrics", version="1.0.0")

    # Get histogram data
    samples, bounds = state.get_and_reset_histogram()

    # Calculate histogram buckets
    bucket_counts = [0] * (len(bounds) + 1)
    total_sum = 0.0
    min_val = float('inf') if samples else 0.0
    max_val = float('-inf') if samples else 0.0

    for s in samples:
        total_sum += s
        min_val = min(min_val, s)
        max_val = max(max_val, s)
        placed = False
        for i, bound in enumerate(bounds):
            if s <= bound:
                bucket_counts[i] += 1
                placed = True
                break
        if not placed:
            bucket_counts[-1] += 1

    if not samples:
        min_val = 0.0
        max_val = 0.0

    metrics_list = [
        # Counter: HTTP requests total
        Metric(
            name="custom_http_requests_total",
            description="Total number of HTTP requests",
            unit="1",
            data=Sum(
                data_points=[
                    NumberDataPoint(
                        attributes={"host.name": state.hostname},
                        start_time_unix_nano=state.start_time_ns,
                        time_unix_nano=now_ns,
                        value=float(state.http_requests),
                    )
                ],
                aggregation_temporality=AggregationTemporality.CUMULATIVE,
                is_monotonic=True,
            ),
        ),
        # Counter: HTTP errors total
        Metric(
            name="custom_http_errors_total",
            description="Total number of HTTP errors",
            unit="1",
            data=Sum(
                data_points=[
                    NumberDataPoint(
                        attributes={"host.name": state.hostname},
                        start_time_unix_nano=state.start_time_ns,
                        time_unix_nano=now_ns,
                        value=float(state.http_errors),
                    )
                ],
                aggregation_temporality=AggregationTemporality.CUMULATIVE,
                is_monotonic=True,
            ),
        ),
        # Histogram: Request duration
        Metric(
            name="custom_http_duration_seconds",
            description="HTTP request duration distribution",
            unit="s",
            data=Histogram(
                data_points=[
                    HistogramDataPoint(
                        attributes={"host.name": state.hostname},
                        start_time_unix_nano=state.start_time_ns,
                        time_unix_nano=now_ns,
                        count=len(samples),
                        sum=total_sum,
                        bucket_counts=tuple(bucket_counts),
                        explicit_bounds=bounds,
                        min=min_val,
                        max=max_val,
                    )
                ],
                aggregation_temporality=AggregationTemporality.CUMULATIVE,
            ),
        ),
        # Gauge: CPU usage (simulated)
        Metric(
            name="custom_system_cpu_usage",
            description="Current CPU usage percentage",
            unit="%",
            data=Gauge(
                data_points=[
                    NumberDataPoint(
                        attributes={"host.name": state.hostname, "cpu": "total"},
                        start_time_unix_nano=state.start_time_ns,
                        time_unix_nano=now_ns,
                        value=random.uniform(20, 70),
                    )
                ],
            ),
        ),
    ]

    scope_metrics = ScopeMetrics(
        scope=scope,
        metrics=metrics_list,
        schema_url=None,
    )

    resource_metrics = ResourceMetrics(
        resource=resource,
        scope_metrics=[scope_metrics],
        schema_url=None,
    )

    return MetricsData(resource_metrics=[resource_metrics])


class CustomMetricReader(MetricReader):
    """Custom MetricReader that uses Producer approach for Counter/Histogram."""

    def __init__(self, exporter: OTLPMetricExporter, state: CustomMetricsState,
                 resource: Resource, export_interval_ms: int = 10000):
        super().__init__()
        self._exporter = exporter
        self._state = state
        self._resource = resource
        self._export_interval = export_interval_ms / 1000.0
        self._shutdown = False
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        while not self._shutdown:
            time.sleep(self._export_interval)
            if not self._shutdown:
                self._export()

    def _export(self):
        try:
            data = create_metrics_data(self._state, self._resource)
            self._exporter.export(data)
        except Exception as e:
            print(f"Export error: {e}")

    def _receive_metrics(self, metrics_data, timeout_millis=10000, **kwargs):
        # Not used - we generate our own metrics
        pass

    def shutdown(self, timeout_millis=30000, **kwargs):
        self._shutdown = True
        self._thread.join(timeout=timeout_millis / 1000.0)
        self._exporter.shutdown()


# ════════════════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════════════════

def main():
    print("=== Custom Metrics Sender (Python/gRPC) ===")
    print(f"Endpoint: {ENDPOINT}")
    print(f"Service:  {SERVICE_NAME}")

    headers = parse_headers(HEADERS)
    print(f"Headers:  {len(headers)} configured")
    print()

    # Create resource
    resource = Resource.create({
        "service.name": SERVICE_NAME,
        "service.version": "1.0.0",
        "host.name": platform.node(),
        "deployment.environment": "demo",
    })

    # Create exporter
    insecure_env = os.getenv("OTEL_EXPORTER_OTLP_INSECURE", "").lower()
    if insecure_env in ("true", "1"):
        insecure = True
    elif insecure_env in ("false", "0"):
        insecure = False
    else:
        insecure = not (":443" in ENDPOINT or ":444" in ENDPOINT)

    exporter = OTLPMetricExporter(
        endpoint=ENDPOINT,
        headers=headers,
        insecure=insecure,
    )

    # Create state for custom metrics
    state = CustomMetricsState()

    # Create custom reader with Producer approach
    reader = CustomMetricReader(exporter, state, resource, export_interval_ms=10000)

    # Create meter provider (for standard API metrics like UpDownCounter)
    provider = MeterProvider(resource=resource)
    metrics.set_meter_provider(provider)
    meter = metrics.get_meter("custom-metrics", "1.0.0")

    # UpDownCounter works via standard API
    active_connections = meter.create_up_down_counter(
        name="custom.http.connections.active",
        description="Number of active HTTP connections",
        unit="1",
    )

    print("Sending metrics every 10 seconds... (Ctrl+C to stop)")
    print()
    print("Metrics (all types work!):")
    print("  Counter:    custom_http_requests_total, custom_http_errors_total")
    print("  Histogram:  custom_http_duration_seconds")
    print("  Gauge:      custom_system_cpu_usage")
    print("  UpDown:     custom.http.connections.active")
    print()

    iteration = 0
    current_connections = 10

    try:
        while True:
            iteration += 1

            # Add request (5% error rate)
            state.add_request(is_error=random.random() < 0.05)
            state.record_duration(0.05 + random.random() * 0.45)

            # Connection changes
            delta = random.randint(-2, 2)
            current_connections = max(0, current_connections + delta)
            active_connections.add(delta, {"service.name": SERVICE_NAME})

            if iteration % 100 == 0:
                print(f"  [{iteration}] requests={state.http_requests} "
                      f"errors={state.http_errors} connections={current_connections}")

            time.sleep(0.1)

    except KeyboardInterrupt:
        print(f"\nStopping after {iteration} iterations...")
        reader.shutdown()
        provider.shutdown()
        print("Done!")


if __name__ == "__main__":
    main()
