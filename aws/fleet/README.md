# nginx-pqc-perf-test on AWS: fleet mode

Benchmark the same PQC-vs-ECDHE TLS 1.3 handshake across a **variety of
hosts and instance types** from one place. A single dedicated **bench
client** (amd64 Amazon Linux 2023) drives the benchmark over the network
against **N nginx target hosts** (any instance type / architecture, Rocky
Linux 9), then consolidates every host's numbers into one comparison
table.

This is the multi-host counterpart to [single-host mode](../README.md),
where one box runs nginx *and* the bench tool over `localhost`. The two
modes are self-contained: fleet mode lives entirely under `aws/fleet/` and
shares no Terraform or Ansible with the single-host path. Both still reuse
the repo-root building blocks unmodified: `bench/main.go`,
`certs/gen-certs.sh`, `html/small.html`, and `scripts/summarize.sh`.

## How it fits together

- **Terraform** (`terraform/`) is modular: a `network` module (one VPC +
  one subnet in one AZ + security groups), an `nginx_target` module
  instantiated once per entry in the `nginx_targets` map, and a
  `bench_client` module. Adding a host to test is a single map entry.
  After the instances come up, Terraform renders the Ansible inventory and
  runs the playbook automatically.
- **Ansible** (`ansible/`) has two roles: `nginx_target` deploys
  nginx-pqc + nginx-classic (systemd services on 8443 / 9443) plus a
  bounded CPU/mem poller; `bench_client` installs Go (from the official
  tarball, to guarantee the >= 1.24 that `X25519MLKEM768` needs), builds
  the bench binary, and drops the run + summarize scripts, the SSH key,
  and the target list.
- **The client** benchmarks each target over its **private** IP
  (intra-VPC) and, for each run, SSHes into the target to sample that
  target's own nginx CPU/mem for the run's duration. Handshake rate and
  latency come from the bench tool; CPU/mem come from the target.

All hosts share one subnet in one AZ, so every measured handshake
traverses the same minimal network path. Terraform picks an AZ that offers
*every* instance type in the fleet (client + all targets).

## Prerequisites

1. **Terraform** >= 1.5 and **Ansible** (`ansible-playbook` on your PATH,
   used by Terraform's auto-run step).
2. AWS credentials with permission to create EC2 instances, VPCs,
   security groups, and key pairs.
3. **One-time manual step**: accept the AWS Marketplace subscription for
   [Rocky Linux 9](https://aws.amazon.com/marketplace/pp/prodview-c755eecdjt7gs)
   for this account/region (the targets are Rocky 9; owner account
   `679593333241`). Without it, `terraform apply` fails with
   `OptInRequired`. The bench client is stock Amazon Linux 2023, no opt-in.
4. Your workstation's public IP for `allowed_ssh_cidr` (Ansible SSHes in
   from here). Required, no default, so SSH is never open to the world.

## Usage

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit: allowed_ssh_cidr, owner, email, nginx_targets
terraform init
terraform apply
```

Define the fleet in `terraform.tfvars`. Architecture is auto-derived from
each instance type (Graviton -> arm64, otherwise x86_64):

```hcl
nginx_targets = {
  c6i = { instance_type = "c6i.large" }   # amd64
  c7g = { instance_type = "c7g.large" }   # Graviton3 (arm64)
  c8g = { instance_type = "c8g.large" }   # Graviton4 (arm64)
}
```

Prefer fixed-performance types over burstable T-series ones: burst-credit
exhaustion would silently throttle a target mid-run and skew this
CPU-bound benchmark. The **client** (`client_instance_type`, default
`c6i.xlarge`) generates every handshake, so keep it comfortably larger
than the targets; if you see it pegged at 100% CPU during a run, scale it
up, otherwise target rates converge on the client's ceiling instead of
measuring the targets.

`terraform apply` generates a fresh SSH key pair
(`terraform/generated/nginx-pqc-perf-test-fleet.pem`, gitignored), renders
`ansible/inventory.ini`, and runs `ansible/site.yml` automatically. To
provision infrastructure only and run Ansible yourself, set
`-var="run_ansible=false"` and then `cd ../ansible && ansible-playbook
site.yml`.

> **Private key in state.** Because this uses `tls_private_key`, the key
> material also lands in Terraform state. Treat local `.tfstate` as
> sensitive (gitignored) and use a remote/encrypted backend for anything
> beyond throwaway testing.

## Running the benchmark

```sh
terraform output client_ssh_command   # ssh -i ... ec2-user@<client-ip>
# ... SSH in, then:
/opt/nginx-pqc-perf-test/run-fleet-benchmark.sh
cat /opt/nginx-pqc-perf-test/results/summary.md
```

Tune the run with env vars (same knobs as the other paths):

```sh
BENCH_DURATION=60s BENCH_CONNS=50 /opt/nginx-pqc-perf-test/run-fleet-benchmark.sh
```

`summary.md` has a PQC row and a Classic row per target, with
handshakes/sec, p50/p95/p99 latency, errors, and the target's CPU / Mem
during the run. Fetch it back with `scp` if you prefer.

## Gotchas

- **Network path is a shared confound.** Unlike single-host mode
  (loopback), every handshake here crosses the intra-VPC network, which
  adds latency to the absolute numbers. Because the client and all targets
  sit in one subnet/AZ, that path is equal for every host, so the
  PQC-vs-Classic delta within a host and the relative ordering of hosts
  stay meaningful. Do not cross-compare these absolute numbers with the
  container or single-host paths.
- **Client sizing.** See above: a too-small client caps every target at
  the same rate and hides real differences.
- **AZ coverage.** Mixing a brand-new family (e.g. `c9g`) with others can
  leave no single AZ offering all of them; `terraform plan` then fails
  fast naming the offending types. Pick types with overlapping coverage or
  change the region.
- **Cost.** This creates one client plus one instance per target, each
  with an EBS volume. `terraform destroy` when done.

## Cleanup

```sh
cd terraform
terraform destroy
```
