# nginx-pqc-perf-test on AWS

Two self-contained ways to run the same PQC-vs-ECDHE TLS 1.3 handshake
benchmark (see the repo root [README](../README.md)) on real EC2 hosts,
directly on the OS with no containers:

- **[Single-host mode](#single-host-mode)** (`single/`): one Rocky Linux 9
  instance runs nginx-pqc, nginx-classic, *and* the bench tool,
  benchmarking over `localhost`. Simplest; answers "what does PQC cost on
  this one box" with no network in the path.
- **[Fleet mode](#fleet-mode)** (`fleet/`): a dedicated amd64 Amazon Linux
  2023 **bench client** drives the benchmark over the network against **N
  nginx target hosts** (any instance type / architecture) and consolidates
  every host's numbers into one comparison table. Use this to compare a
  variety of hosts and instance types from one place.

The two modes are independent: they share no Terraform or Ansible with
each other. Both reuse the repo-root building blocks unmodified, copied in
by Ansible rather than duplicated: `bench/main.go` (the handshake tool),
`certs/gen-certs.sh` (the shared cert), `html/small.html`, and
`scripts/summarize.sh` (results table).

> For an exact, copy-pasteable command sequence to run either mode end to
> end, see the "Running the AWS benchmarks (runbook)" section of the
> repo-root [`CLAUDE.md`](../CLAUDE.md).

## Shared prerequisites

1. **Terraform** >= 1.5 and **Ansible** (`ansible-playbook` on your PATH).
2. **AWS credentials** configured (env vars, `~/.aws/credentials`, or SSO)
   with permission to create EC2 instances, VPCs, security groups, and key
   pairs. `terraform apply` fails immediately without them.
3. **One-time manual step**: accept the AWS Marketplace subscription for
   [Rocky Linux 9](https://aws.amazon.com/marketplace/pp/prodview-c755eecdjt7gs)
   via the AWS Console, for the account/region you deploy into. Rocky
   Linux AMIs are Marketplace-only (owner account `679593333241`); without
   this, `terraform apply` fails with `OptInRequired`. (Fleet's bench
   client is stock Amazon Linux 2023 and needs no opt-in.)
4. Your workstation's public IP (or CIDR) for `allowed_ssh_cidr`, a
   required Terraform variable with no default on purpose, so you don't
   accidentally open SSH to the whole internet.

All commands below assume you start in this `aws/` directory.

---

## Single-host mode

Runs nginx **directly** on one Rocky Linux 9 EC2 instance, no
Podman/Docker. Terraform provisions the instance; Ansible installs and
configures everything on it, then you run the benchmark over `localhost`
on the box. The only genuinely new logic versus the container path is the
`nginx.conf`/systemd unit templates for a native dual-instance setup and a
bare-metal orchestration script (`run-benchmark.sh` here uses `ps`/`pgrep`
for CPU/mem instead of `docker stats`).

### Provision

```sh
cd single/terraform
terraform init
terraform apply -var="allowed_ssh_cidr=YOUR_IP/32" \
  -var="owner=you" -var="email=you@example.com"
```

`instance_type` defaults to `c6i.large` (a fixed-performance type; see the
comment in `variables.tf` for why burstable T-series types are a bad
default for a CPU-bound crypto benchmark) but is fully overridable, e.g.
`-var="instance_type=m6i.xlarge"`.

#### Graviton / ARM (e.g. c9g)

To benchmark on AWS Graviton, just point `instance_type` at a Graviton
family; that is the only change needed:

```sh
terraform apply -var="instance_type=c9g.large" -var="allowed_ssh_cidr=YOUR_IP/32" \
  -var="owner=you" -var="email=you@example.com"
```

The CPU architecture is auto-derived from `instance_type`, so a Graviton
family (Graviton5 c9g/c9gd, c8g, m7g, r8g, t4g, …) automatically selects
the arm64 Rocky Linux 9 AMI, and the subnet is placed in an AZ that
actually offers the type (newly launched families like c9g aren't offered
in every AZ). The rest (Ansible, nginx, Go, the bench tool) is
architecture-agnostic; the bench binary is built from source on the
instance, so it comes out native aarch64.

Notes:
- The one-time **Rocky Linux 9 Marketplace subscription** covers the arm64
  AMI too; same product, no separate opt-in.
- **c9g region availability**: US East (Ohio `us-east-2`, the default
  region), US East (N. Virginia `us-east-1`), US West (Oregon `us-west-2`),
  Europe (Frankfurt `eu-central-1`). If your `region`/`instance_type`
  combo isn't offered, `terraform plan` fails fast telling you so.
- `ami_architecture` is only an escape hatch; normally you set just
  `instance_type` and the architecture is read authoritatively from AWS.
  If you do set it, it must match the instance type's architecture or
  `terraform plan` fails with a clear mismatch message.

`terraform apply` generates a fresh SSH key pair and writes the private
key to `single/terraform/generated/nginx-pqc-perf-test.pem` (gitignored).

> **Private key in state.** Because this uses `tls_private_key`, the key
> material also ends up in Terraform state; treat local `.tfstate` files
> as sensitive (gitignored) and use a remote/encrypted backend if this
> ever becomes more than throwaway testing.

### Configure and run

```sh
terraform output          # public_ip, private_key_path, ssh_command

cd ../ansible
cp inventory.ini.example inventory.ini
# edit inventory.ini: fill in ansible_host and ansible_ssh_private_key_file
# from the terraform outputs above
ansible-playbook playbook.yml
```

The playbook installs nginx (from the official nginx.org repo; Rocky's own
AppStream package is a very old 1.20.1), Go, and jq; generates the shared
cert; deploys `nginx-pqc` and `nginx-classic` as independent systemd
services on ports 8443/9443; sets the SELinux contexts Rocky 9's enforcing
policy requires; builds the bench binary from source; and runs the same
TLS-group-negotiation sanity checks the container path runs.

Then, on the instance:

```sh
ssh -i $(terraform -chdir=../terraform output -raw private_key_path) \
  rocky@$(terraform -chdir=../terraform output -raw public_ip)

sudo /opt/nginx-pqc-perf-test/run-benchmark.sh
cat /opt/nginx-pqc-perf-test/results/summary.md
```

Or fetch results back instead of reading them over SSH:

```sh
scp -i <key> rocky@<ip>:/opt/nginx-pqc-perf-test/results/summary.md .
```

### Gotchas

- **Key pairs and regions**: the generated key pair lives in whatever
  `var.region` you deployed to (default `us-east-2`). Point Ansible/SSH at
  the wrong region's IP with the wrong key and you just get a connection
  failure, not a helpful error.
- **Native results aren't directly comparable to the container-path
  numbers** in the repo root: different network path (real loopback vs. a
  container bridge network), different nginx version, no container runtime
  overhead. This mode measures PQC overhead without a container as a
  possible confound, not to cross-compare against the Docker/Podman
  results.
- **Cost**: this creates a real, billed EC2 instance plus an EBS volume.
  `terraform destroy` when done.

### Cleanup

```sh
cd single/terraform
terraform destroy -var="allowed_ssh_cidr=YOUR_IP/32" \
  -var="owner=you" -var="email=you@example.com"
```

---

## Fleet mode

A single dedicated **bench client** (amd64 Amazon Linux 2023) drives the
benchmark over the network against **N nginx target hosts** (any instance
type / architecture, Rocky Linux 9) and consolidates every host's numbers
into one comparison table.

### How it fits together

- **Terraform** (`fleet/terraform/`) is modular: a `network` module (one
  VPC + one subnet in one AZ + security groups), an `nginx_target` module
  instantiated once per entry in the `nginx_targets` map, and a
  `bench_client` module. Adding a host to test is a single map entry.
  After the instances come up, Terraform renders the Ansible inventory and
  runs the playbook automatically.
- **Ansible** (`fleet/ansible/`) has two roles: `nginx_target` deploys
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

### Provision (auto-runs Ansible)

```sh
cd fleet/terraform
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
(`fleet/terraform/generated/nginx-pqc-perf-test-fleet.pem`, gitignored),
renders `fleet/ansible/inventory.ini`, and runs `fleet/ansible/site.yml`
automatically. To provision infrastructure only and run Ansible yourself,
set `-var="run_ansible=false"` and then `cd ../ansible && ansible-playbook
site.yml`.

> **Private key in state**, same caveat as single-host mode above.

### Run the benchmark

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

### Gotchas

- **Network path is a shared confound.** Unlike single-host mode
  (loopback), every handshake here crosses the intra-VPC network, which
  adds latency to the absolute numbers. Because the client and all targets
  sit in one subnet/AZ, that path is equal for every host, so the
  PQC-vs-Classic delta within a host and the relative ordering of hosts
  stay meaningful. Do not cross-compare these absolute numbers with the
  container or single-host paths.
- **Client sizing.** A too-small client caps every target at the same rate
  and hides real differences.
- **AZ coverage.** Mixing a brand-new family (e.g. `c9g`) with others can
  leave no single AZ offering all of them; `terraform plan` then fails
  fast naming the offending types. Pick types with overlapping coverage or
  change the region.
- **Cost.** This creates one client plus one instance per target, each
  with an EBS volume. `terraform destroy` when done.

### Cleanup

```sh
cd fleet/terraform
terraform destroy
```
