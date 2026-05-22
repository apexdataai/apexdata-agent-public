FROM golang:1.26-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY send_logs.go .
RUN CGO_ENABLED=0 go build -o /send-logs send_logs.go

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder /send-logs /usr/local/bin/send-logs
ENTRYPOINT ["send-logs"]
