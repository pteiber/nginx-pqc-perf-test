# nginx-pqc-perf-test

Benchmarks raw TLS 1.3 handshake performance on nginx configured two
ways, and compares handshake rate, latency, CPU, and memory between them:

- **PQC**: offers the hybrid post-quantum KEM `X25519MLKEM768` (falls
  back to classical `X25519`)
- **Classic**: offers `X25519` only (plain ECDHE)

Both targets run the exact same official `nginx:1.31.2` image (OpenSSL
3.5.x) and the exact same ECDSA P-256 certificate (no custom image
build). The **only** difference between them is the `ssl_conf_command
Groups` line in their `nginx.conf` (see `nginx/pqc/nginx.conf` vs
`nginx/classic/nginx.conf`). That's deliberate: it isolates the TLS
key-exchange algorithm as the one independent variable, so any
difference you observe in the results is attributable to the KEM, not to
a different code path, cert, or config.

OpenSSL >= 3.5 added native support for ML-KEM and the `X25519MLKEM768`
hybrid group, so nginx needs no third-party provider or custom build;
the official image already supports it out of the box.

## Prerequisites

- **Podman** or **Docker**, with Compose support (`podman compose` /
  `docker compose`, or the standalone `podman-compose`)
- **curl**: used by the orchestration script to wait for nginx to become
  ready, and to run manual checks
- **jq**: used by `scripts/summarize.sh` to render the results table
  (optional: the raw JSON in `results/*.json` is always written
  regardless of whether `jq` is installed)

Tested with Podman 6.0 + podman-compose 1.6.0 on macOS. Nothing here is
Podman-specific: `scripts/run-benchmark.sh` auto-detects Docker too.

## Quickstart

```sh
./scripts/run-benchmark.sh
```

This starts both nginx targets (pulling `nginx:1.31.2` if needed, no
image build), generates a shared cert, confirms each target negotiates
the TLS group it's supposed to, runs the handshake benchmark against
both, and tears everything down when it's done. Results land in
`results/`:

- `results/<scenario>.json`: raw output from the bench tool
- `results/<scenario>-stats.log`: raw CPU%/memory samples polled once a
  second during that scenario
- `results/summary.md`: the same table printed to stdout at the end

Tune the run with environment variables:

```sh
BENCH_DURATION=60s BENCH_CONNS=50 ./scripts/run-benchmark.sh
```

| Variable | Default | Meaning |
|---|---|---|
| `BENCH_DURATION` | `30s` | how long each scenario runs |
| `BENCH_CONNS` | `20` | concurrent workers dialing handshakes |

## Repo layout

```
compose.yaml              certs (init job) + nginx-pqc + nginx-classic (image: nginx:1.31.2) + bench
nginx/pqc/nginx.conf      Groups X25519MLKEM768:X25519, mounted into the official nginx image
nginx/classic/nginx.conf  Groups X25519, mounted into the official nginx image
html/small.html           served payload used for readiness/manual checks
certs/gen-certs.sh        generates the shared ECDSA P-256 cert (runs in the certs service)
bench/main.go             the handshake benchmark tool
bench/Dockerfile          builds the bench tool on golang:1.24-bookworm (see Notes)
scripts/run-benchmark.sh  orchestrates a full local (container) run
scripts/summarize.sh      renders results/*.json into a markdown table
results/                  benchmark output (gitignored, except .gitkeep)
aws/                      run the same benchmark on real EC2 hosts (see aws/README.md)
aws/single/               one Rocky 9 box runs nginx + bench over localhost
aws/fleet/                a bench client drives N nginx target hosts over the network
```

The `bench/`, `certs/gen-certs.sh`, `html/small.html`, and
`scripts/summarize.sh` building blocks are reused unmodified by the AWS
deployments; only the container path uses `compose.yaml` and
`scripts/run-benchmark.sh`.

## What's measured

**Handshake rate**: the bench tool opens a brand-new TLS connection per
iteration (no session resumption, no HTTP keep-alive) across N
concurrent workers, for the configured duration, and reports
handshakes/sec plus latency percentiles. This isolates the cost of the
key exchange itself, which is where PQC overhead shows up most directly
(ML-KEM has larger public keys and ciphertexts than X25519, so the
ClientHello/ServerHello exchange does more work and moves more bytes).

**Concurrency model**: the bench tool spawns `-conns` goroutines (default
20), each running sequentially: dial -> TLS 1.3 handshake -> close ->
immediately repeat. All workers run concurrently with no coordination, so
nginx sees at most N handshakes in flight at any moment. This is a
closed-loop workload: throughput = N / mean_latency. The reported
handshakes/sec reflects the natural throughput the system sustains under
that concurrency level, not an injected request rate. Raising `-conns`
increases concurrency and can increase throughput until nginx saturates.

**CPU / memory**: `podman stats` / `docker stats` is polled once a
second against the nginx container under test throughout each scenario
(or `ps` sampling at 1Hz on a bare-metal deployment). Because
`nginx.conf` sets `worker_processes auto`, CPU% can exceed 100% on
multi-core hosts (each worker process is counted). Both targets use
the same `worker_processes auto` setting, so this doesn't bias the
comparison.

## Reading the results

Example output from a local run (macOS, Podman, Apple Silicon, 5s
duration; not a real benchmark, just illustrating the shape of the
output; run it yourself with the default 30s duration for real numbers):

| Scenario | TLS Group | Handshakes/sec | p50 (ms) | Avg CPU | Mem |
|---|---|---|---|---|---|
| PQC | X25519MLKEM768 | 6722 | 1.29 | 52.1% | 11.4MB |
| Classic | X25519 | 9047 | 0.94 | 32.8% | 10.3MB |

In this run, PQC handshakes were slower and more CPU-hungry than
classical ECDHE; consistent with ML-KEM doing more computation and
moving more bytes per handshake than X25519 alone.

Treat absolute numbers as specific to the host they were measured on
(container runtime overhead, CPU, host load all matter); the point of
this harness is the **relative** PQC-vs-classic comparison under
identical conditions, not an absolute number to quote elsewhere.

## Running on real hardware (AWS)

The quickstart above runs everything in containers on your workstation.
To run the identical benchmark on real EC2 instances natively (no
containers), see [`aws/README.md`](aws/README.md). Two modes are provided:

- **single-host**: one Rocky Linux 9 box runs both nginx targets and the
  bench tool over `localhost`; measures PQC cost on one machine.
- **fleet**: a dedicated bench client drives the benchmark over the network
  against N nginx hosts (any instance type / architecture) and consolidates
  every host into one comparison table.

Both are provisioned with Terraform + Ansible and reuse the building blocks
above. They launch billed EC2 instances, so `terraform destroy` when done.

## Manual verification

Confirm nginx-pqc actually negotiates the PQC group:

```sh
openssl s_client -connect localhost:8443 -groups X25519MLKEM768 -brief
# look for: Negotiated TLS1.3 group: X25519MLKEM768
```

Confirm nginx-classic only offers classical X25519 (no `-groups` needed:
it's the only group configured):

```sh
openssl s_client -connect localhost:9443 -brief
# look for: Peer Temp Key: X25519, 253 bits
```

And confirm nginx-classic *rejects* a PQC-only offer (this should fail):

```sh
openssl s_client -connect localhost:9443 -groups X25519MLKEM768
# expected: ssl3_read_bytes:tls alert handshake failure
```

If your host OpenSSL is older than 3.5 and doesn't recognize
`X25519MLKEM768`, run the same checks from inside the nginx-pqc container
instead, which always has a compatible OpenSSL build:

```sh
podman compose -p pqcbench run --rm -T --no-deps --entrypoint openssl nginx-pqc \
  s_client -connect nginx-pqc:443 -groups X25519MLKEM768 -brief </dev/null
```

## Extending the harness

- **Add a KEM or group**: edit the `ssl_conf_command Groups ...` line in
  `nginx/pqc/nginx.conf` (or add a third `nginx/<variant>/nginx.conf` and
  a matching compose service following the same pattern) and add a
  matching `tls.CurveID` case in `bench/main.go`'s `-pqc` handling if
  it's a group Go's `crypto/tls` doesn't already know about.
- **Add a PQC-signature/certificate scenario**: both targets currently
  share one ECDSA P-256 cert generated by `certs/gen-certs.sh` so only
  the KEM varies. To isolate signature-algorithm overhead too, generate
  a second cert (e.g. ML-DSA) and add a third nginx variant + compose
  service pointing at it: the bench tool and orchestration script don't
  need to change, since neither cares about the signature algorithm.
- **Bring back a throughput/application-layer scenario**: `bench/main.go`
  currently only measures raw handshakes; if you need to measure
  keep-alive request throughput again, add an HTTP client mode alongside
  `runHandshake` and a matching payload under `html/`.
- **Find the breaking point**: increase `-conns` in steps (e.g., 20 -> 50
  -> 100 -> 200 -> 500) to stress-test nginx. Since this is a closed-loop
  workload, workers pile up pressure as each handshake takes longer under
  load. Watch for saturation signals: throughput plateaus or drops while
  p95/p99 latency climbs sharply, or errors appear in the JSON output.
  CPU is the expected bottleneck: since `worker_processes auto` matches
  core count, a 2-core instance saturates near 200% avg CPU. When testing
  high concurrency, also increase `-duration` to capture steady-state
  thermal/throttle behavior. Example: sweep concurrency and save separate
  result files:
  ```sh
  for conns in 20 50 100 200 500; do
    ./bench/bench -addr localhost:8443 -pqc -conns $conns -duration 30s \
      -scenario pqc-$conns -out results/pqc-$conns.json
  done
  ./scripts/summarize.sh results
  ```

## Notes

- The `certs` service is a one-shot job (`condition:
  service_completed_successfully`) that both nginx services depend on;
  `certs/gen-certs.sh` is idempotent, so re-running compose doesn't
  regenerate the cert unnecessarily.
- Both nginx services use the official `nginx:1.31.2` image unmodified:
  `nginx.conf`, `html/`, and the shared cert are all bind-mounted in via
  `compose.yaml`, so there's nothing to build or rebuild when you change
  a config.
- The bench tool builds and runs in its own container
  (`golang:1.24-bookworm`) rather than relying on the host's Go
  toolchain. This matters: `tls.X25519MLKEM768` requires Go >= 1.24 to
  actually negotiate (older toolchains accept the constant but silently
  produce zero usable curves): see `bench/go.mod`'s `go 1.24` directive.
