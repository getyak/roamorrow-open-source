FROM golang:1.27.4-alpine@sha256:0a5f7fe796599ff487605987432e7619ae45beeb2fba4c2ce0b907879932aebf AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN GOMAXPROCS=2 go mod download
COPY . .
ARG SOURCE_REVISION=unknown
RUN GOMAXPROCS=2 CGO_ENABLED=0 GOOS=linux go build -p 2 -ldflags "-X main.buildRevision=${SOURCE_REVISION}" -o /api-server .

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
RUN apk --no-cache add ca-certificates \
    && addgroup -S app \
    && adduser -S -G app app
WORKDIR /app
COPY --from=builder /api-server .
# Harness migrations ship inside the runtime image (applied idempotently at
# startup or via `api-server migrate`).
COPY --from=builder /app/migrations /app/migrations
RUN chmod -R a+rX /app/migrations
USER app
EXPOSE 8080
ENTRYPOINT ["/app/api-server"]
