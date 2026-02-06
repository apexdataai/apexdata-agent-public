FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY send_metrics.go .
RUN CGO_ENABLED=0 go build -o /send-metrics send_metrics.go

FROM alpine:3.20
COPY --from=builder /send-metrics /usr/local/bin/send-metrics
ENTRYPOINT ["send-metrics"]
