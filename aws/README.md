# nginx-pqc-perf-test on AWS

Run the PQC-vs-ECDHE TLS 1.3 handshake benchmark (see the repo root
[README](../README.md)) on real EC2 hosts, natively on the OS (no
containers). Two independent modes:

- **[Single-host](#single-host-mode)** (`single/`): one Rocky Linux 9 box
  runs both nginx targets and the bench tool, benchmarking over
  `localhost`. Simplest way to measure PQC cost on one machine.
- **[Fleet](#fleet-mode)** (`fleet/`): a dedicated bench client drives the
  benchmark over the network against N nginx hosts (any instance type or
  architecture) and consolidates every host into one comparison table.

Both cost real money (they launch EC2 instances). `terraform destroy` when
you are done.

## Prerequisites

1. **Terraform** >= 1.5 and **Ansible** (`ansible-playbook` on your PATH).
2. **AWS credentials** active: `aws sts get-caller-identity` must succeed.
3. **Accept the [Rocky Linux 9](https://aws.amazon.com/marketplace/pp/prodview-c755eecdjt7gs)
   Marketplace subscription** once, in the AWS Console, for your target
   region. Without it, `terraform apply` fails with `OptInRequired`.
4. **Your public IP** for `allowed_ssh_cidr`:
   `curl -s https://checkip.amazonaws.com` then append `/32`.

Replace `YOUR_IP/32`, `you`, and `you@example.com` below with real values.

---

## Single-host mode

### Provision

```sh
cd single/terraform
terraform init
terraform apply -var="allowed_ssh_cidr=YOUR_IP/32" \
  -var="owner=you" -var="email=you@example.com"
```

`instance_type` defaults to `c6i.large` and is overridable, e.g.
`-var="instance_type=c8g.large"`. Graviton families auto-select the arm64
AMI; nothing else changes.

### Configure and run

```sh
cd ../ansible
cp inventory.ini.example inventory.ini
# set ansible_host to:              terraform -chdir=../terraform output -raw public_ip
# set ansible_ssh_private_key_file: terraform -chdir=../terraform output -raw private_key_path
ansible-playbook playbook.yml

# run the benchmark on the box (bench talks to localhost):
ssh -i "$(terraform -chdir=../terraform output -raw private_key_path)" \
  rocky@"$(terraform -chdir=../terraform output -raw public_ip)" \
  'sudo /opt/nginx-pqc-perf-test/run-benchmark.sh && cat /opt/nginx-pqc-perf-test/results/summary.md'
```

Tune with `BENCH_CONNS` (default 20) and `BENCH_DURATION` (default 30s).
The script runs under `sudo`, which strips the environment, so pass the
vars *through* sudo:

```sh
sudo BENCH_DURATION=60s BENCH_CONNS=50 /opt/nginx-pqc-perf-test/run-benchmark.sh
```

### Cleanup

```sh
cd single/terraform
terraform destroy -var="allowed_ssh_cidr=YOUR_IP/32" \
  -var="owner=you" -var="email=you@example.com"
```

---

## Fleet mode

Ansible runs automatically as part of `terraform apply` here; you only run
the benchmark by hand afterward.

### Provision (auto-runs Ansible)

```sh
cd fleet/terraform
cp terraform.tfvars.example terraform.tfvars
# edit: allowed_ssh_cidr, owner, email, and the nginx_targets map
terraform init
terraform apply
```

Define the fleet in `terraform.tfvars`. One entry per host to test;
architecture is auto-derived (Graviton -> arm64, otherwise x86_64):

```hcl
nginx_targets = {
  c6i = { instance_type = "c6i.large" }   # amd64
  c7g = { instance_type = "c7g.large" }   # Graviton3 (arm64)
  c8g = { instance_type = "c8g.large" }   # Graviton4 (arm64)
}
```

If `terraform apply` succeeds but the Ansible step fails (e.g. a target
still booting), just re-run `terraform apply`; it re-triggers only Ansible.

### Run the benchmark

The benchmark runs from the client and hits every target over the network:

```sh
SSH_CMD="$(terraform output -raw client_ssh_command)"
$SSH_CMD '/opt/nginx-pqc-perf-test/run-fleet-benchmark.sh && cat /opt/nginx-pqc-perf-test/results/summary.md'
# ($SSH_CMD is intentionally unquoted so it splits into the ssh command and its args.)
```

`summary.md` has a PQC and a Classic row per target: handshakes/sec,
p50/p95/p99 latency, errors, and the target's CPU / Mem during the run.

Tune with `BENCH_CONNS` (default 20) and `BENCH_DURATION` (default 30s). No
sudo here (the client script runs as `ec2-user`):

```sh
BENCH_DURATION=60s BENCH_CONNS=50 /opt/nginx-pqc-perf-test/run-fleet-benchmark.sh
```

### Cleanup

```sh
cd fleet/terraform
terraform destroy
```
