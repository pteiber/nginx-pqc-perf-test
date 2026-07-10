# The bench tool is built and run in a container so results don't depend
# on the host's Go version. tls.X25519MLKEM768 requires Go >= 1.24 for
# CurvePreferences to actually negotiate it (older toolchains accept the
# constant but silently produce "no supported elliptic curves").
FROM golang:1.24-bookworm AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /out/bench .

FROM debian:bookworm-slim
COPY --from=builder /out/bench /usr/local/bin/bench
ENTRYPOINT ["/usr/local/bin/bench"]
