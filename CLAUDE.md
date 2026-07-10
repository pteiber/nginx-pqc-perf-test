# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Benchmarks raw TLS 1.3 handshake performance on nginx configured two ways:
- **PQC**: offers the hybrid post-quantum KEM `X25519MLKEM768` (falls back to classical `X25519`)
- **Classic**: offers `X25519` only (plain ECDHE)

Both targets run the identical official `nginx:1.31.2` image (OpenSSL 3.5.x, which natively supports `X25519MLKEM768` — no third-party provider or custom nginx build needed) and the identical ECDSA P-256 certificate. **The only difference between `nginx/pqc/nginx.conf` and `nginx/classic/nginx.conf` is the `ssl_conf_command Groups` line.** This is deliberate and load-bearing: it isolates the TLS key-exchange algorithm as the one independent variable, so any measured difference is attributable to the KEM, not to a different code path, cert, or config. Preserve this property when editing either config — don't let unrelated settings drift between the two files.

## Commands

Run the full benchmark (starts both nginx targets, verifies TLS group negotiation, runs both scenarios, tears down):
```sh
./scripts/run-benchmark.sh
```

Tune via env vars:
```sh
BENCH_DURATION=60s BENCH_CONNS=50 ./scripts/run-benchmark.sh
```
(`BENCH_DURATION` default `30s`, `BENCH_CONNS` default `20`)

Re-render `results/summary.md` from existing `results/*.json` + `*-stats.log` without re-running the benchmark:
```sh
./scripts/summarize.sh results
```

Build/run the bench tool directly (outside Compose) for iterating on `bench/main.go`:
```sh
cd bench && go build -o bench . && ./bench -addr localhost:8443 -pqc -conns 20 -duration 10s -scenario test
```
Note: `bench/go.mod` requires `go 1.24` — older Go toolchain directives cause `tls.X25519MLKEM768` to silently produce zero usable curves in `CurvePreferences` (accepted at compile time, fails at negotiation time). This is why the bench container in `bench/Dockerfile` pins `golang:1.24-bookworm` explicitly rather than trusting whatever Go is on the host.

Manually verify TLS group negotiation against a running stack:
```sh
openssl s_client -connect localhost:8443 -groups X25519MLKEM768 -brief   # expect: Negotiated TLS1.3 group: X25519MLKEM768
openssl s_client -connect localhost:9443 -groups X25519MLKEM768          # expect: handshake failure (classic only offers X25519)
```
If host OpenSSL is older than 3.5 and doesn't know the group, run the same check from inside the nginx-pqc container instead (see README.md's "Manual verification" section for the exact `compose run --entrypoint openssl` invocation).

There is no linter/test suite in this repo; `scripts/run-benchmark.sh` is itself the end-to-end verification (it asserts correct TLS group negotiation for both targets before/as part of running).

## Architecture

- **`compose.yaml`** wires four services: `certs` (one-shot job, generates the shared cert via `certs/gen-certs.sh`, other services `depends_on: condition: service_completed_successfully`), `nginx-pqc` (port 8443→443), `nginx-classic` (port 9443→443), and `bench` (built from `bench/Dockerfile`, invoked via `compose run --rm bench ...` rather than left running). Both nginx services mount their config, `html/`, and the shared cert volume into the *unmodified* upstream image — there is no custom nginx image build.
- **`bench/main.go`** is a from-scratch TLS client (not `curl`/`wrk`/etc.) because it needs `crypto/tls`'s `CurvePreferences: []tls.CurveID{tls.X25519MLKEM768}` to force the PQC group specifically. It dials a fresh TCP+TLS connection per iteration (no session resumption, no HTTP) across N concurrent goroutines for a fixed duration, and reports handshakes/sec + latency percentiles as JSON. It used to also have an HTTP keep-alive throughput mode; that was deliberately removed to keep the tool focused on raw handshake cost (see "Extending the harness" in README.md if reviving it).
- **`scripts/run-benchmark.sh`** auto-detects `podman compose` / `docker compose` / standalone `podman-compose` (tries `$ENGINE compose version` first, falls back to `podman-compose`), waits for both targets to answer HTTP 200, sanity-checks negotiated TLS groups the same way described above, then for each scenario polls `podman/docker stats --no-stream` into `results/<scenario>-stats.log` while `compose run --rm bench ...` executes, producing `results/<scenario>.json`.
- **`scripts/summarize.sh`** is pure `jq`/`awk` over `results/*.json` + `*-stats.log`, decoupled from how those files were produced — this is why it's reused verbatim by the (currently unmerged, `feature/aws` branch) bare-metal Rocky Linux deployment instead of being container-aware. If touching the CPU-average `awk` logic, note that `gsub()` on a field clears awk's STRNUM flag, so numeric checks must use a regex match (`$1 ~ /^[0-9]+(\.[0-9]+)?$/`) rather than `$1+0==$1` — the latter silently drops any sample landing on a round decimal like `3.0`.
- **`certs/gen-certs.sh`** and `html/small.html` have no container-specific assumptions (plain POSIX sh + openssl, static file) — they're mounted/copied as-is by both the container path and the AWS bare-metal path.
