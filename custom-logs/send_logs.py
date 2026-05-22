"""Send custom OTLP logs to the ApexData collector.

Uses the OpenTelemetry LoggingHandler: standard `logging` calls are shipped to the
collector as OTLP LogRecords. Each request is handled inside a trace span, so the
log records carry TraceId/SpanId.

Usage:
    python send_logs.py

Environment variables:
    OTEL_EXPORTER_OTLP_ENDPOINT  - Collector endpoint (default: localhost:4317)
    OTEL_EXPORTER_OTLP_HEADERS   - Auth headers (default: none)
    OTEL_SERVICE_NAME            - Service name (default: custom-logs-python)
    OTEL_EXPORTER_OTLP_INSECURE  - "true" disables TLS (default: false)
"""

import logging
import os
import random
import signal
import socket
import time

from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.trace import get_tracer, set_tracer_provider


def get_env(key, fallback):
    return os.environ.get(key) or fallback


def parse_headers(headers_str):
    headers = {}
    for pair in headers_str.split(","):
        pair = pair.strip()
        if "=" in pair:
            key, _, value = pair.partition("=")
            # gRPC metadata keys must be lowercase; normalize here so that
            # env vars like "Authorization=…" work without manual casing.
            key, value = key.strip().lower(), value.strip()
            if key and value:
                headers[key] = value
    return headers


def main():
    endpoint = get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317")
    headers_str = get_env("OTEL_EXPORTER_OTLP_HEADERS", "")
    service_name = get_env("OTEL_SERVICE_NAME", "custom-logs-python")
    insecure = get_env("OTEL_EXPORTER_OTLP_INSECURE", "false") == "true"
    headers = parse_headers(headers_str)

    # The gRPC exporter wants host:port — strip any scheme.
    endpoint = endpoint.replace("https://", "").replace("http://", "")

    print("=== Custom Logs Sender (Python/gRPC) ===")
    print(f"Endpoint: {endpoint}")
    print(f"Service:  {service_name}")
    print(f"Headers:  {len(headers)} configured\n")

    resource = Resource.create({
        "service.name": service_name,
        "service.version": "1.0.0",
        "host.name": socket.gethostname(),
        "deployment.environment": "demo",
    })

    logger_provider = LoggerProvider(resource=resource)
    set_logger_provider(logger_provider)
    exporter = OTLPLogExporter(endpoint=endpoint, headers=headers, insecure=insecure)
    logger_provider.add_log_record_processor(BatchLogRecordProcessor(exporter))

    handler = LoggingHandler(level=logging.NOTSET, logger_provider=logger_provider)
    # OTel's LoggingHandler formats the record into the OTLP Body. Use a bare
    # "%(message)s" formatter so the Body is just the message — the level travels
    # in SeverityText, not baked into the text. (basicConfig would otherwise apply
    # logging.BASIC_FORMAT here.)
    handler.setFormatter(logging.Formatter("%(message)s"))
    logging.basicConfig(level=logging.INFO, handlers=[handler])
    log = logging.getLogger("custom-logs")

    tracer_provider = TracerProvider(resource=resource)
    set_tracer_provider(tracer_provider)
    tracer = get_tracer("custom-logs")

    running = {"on": True}

    def stop(*_):
        running["on"] = False

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    print("Sending logs every 2 seconds... (Ctrl+C to stop)")
    print("Severities: INFO (normal), WARN (slow), ERROR (failed)\n")

    routes = ["/api/users", "/api/orders", "/api/checkout", "/healthz"]
    iteration = 0
    while running["on"]:
        iteration += 1
        route = random.choice(routes)
        duration_ms = random.randint(0, 500)
        status = 200

        # Each request handled inside a span -> logs carry TraceId/SpanId.
        with tracer.start_as_current_span("handle_request"):
            roll = random.random()
            if roll < 0.1:
                status = 500
                log.error("request failed", extra={
                    "http.method": "GET",
                    "http.route": route,
                    "http.status_code": status,
                    "duration_ms": duration_ms,
                    "error": "upstream timeout",
                })
            elif duration_ms > 350:
                log.warning("slow request", extra={
                    "http.method": "GET",
                    "http.route": route,
                    "http.status_code": status,
                    "duration_ms": duration_ms,
                })
            else:
                log.info("request handled", extra={
                    "http.method": "GET",
                    "http.route": route,
                    "http.status_code": status,
                    "duration_ms": duration_ms,
                })

        if iteration % 10 == 0:
            print(f"  [{iteration}] logs sent")
        time.sleep(2)

    print(f"\nStopping after {iteration} iterations...")
    logger_provider.shutdown()
    tracer_provider.shutdown()
    print("Done!")


if __name__ == "__main__":
    main()
