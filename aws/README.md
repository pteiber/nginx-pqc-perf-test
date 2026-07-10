# nginx-pqc-perf-test on AWS (Rocky Linux 9, no containers)

A second deployment target for the same PQC-vs-ECDHE TLS 1.3 handshake
benchmark described in the repo root [README](../README.md) — this one
runs nginx **directly** on a Rocky Linux 9 EC2 instance, no Podman/Docker
involved. Terraform provisions the instance; Ansible installs and
configures everything on it.

Reuses the same building blocks as the container path, unmodified where
possible: `bench/main.go` (the handshake benchmark tool), `certs/gen-certs.sh`
(the shared cert), `html/small.html`, and `scripts/summarize.sh` (results
table) are all copied from the repo root by the Ansible playbook, not
duplicated. The only genuinely new logic is `nginx.conf`/systemd unit
templates adapted for a native dual-instance setup, and a bare-metal
version of the orchestration script (`run-benchmark.sh` here uses
`ps`/`pgrep` for CPU/mem instead of `docker stats`).

## Prerequisites

1. **Terraform** >= 1.5 and **Ansible** (`ansible-playbook` on your PATH).
2. AWS credentials configured (env vars, `~/.aws/credentials`, or SSO) with
   permission to create EC2 instances, security groups, and key pairs.
3. **One-time manual step**: accept the AWS Marketplace subscription for
   [Rocky Linux 9](https://aws.amazon.com/marketplace/pp/prodview-c755eecdjt7gs)
   via the AWS Console, for the account/region you're deploying into.
   Rocky Linux AMIs are Marketplace-only (owner account `679593333241`) —
   without this, `terraform apply` fails with `OptInRequired`.
4. Your public IP (or CIDR range) to fill in `allowed_ssh_cidr` — this is
   a required Terraform variable with no default on purpose, so you don't
   accidentally open SSH to the whole internet.

## Usage

```sh
cd terraform
terraform init
terraform apply -var="allowed_ssh_cidr=YOUR_IP/32"
```

`instance_type` defaults to `c6i.large` (a fixed-performance type — see
the comment in `variables.tf` for why burstable T-series types are a bad
default for a CPU-bound crypto benchmark) but is fully overridable, e.g.
`-var="instance_type=m6i.xlarge"`. No size was assumed; pick whatever fits
your testing.

`terraform apply` generates a fresh SSH key pair (not a pre-existing one)
and writes the private key to `terraform/generated/nginx-pqc-perf-test.pem`
(gitignored). **Note:** because this uses `tls_private_key`, the private
key material also ends up in Terraform state — treat local `.tfstate`
files as sensitive (already gitignored), and use a remote/encrypted
backend if this ever becomes more than throwaway testing.

Once `apply` finishes:

```sh
terraform output          # public_ip, private_key_path, ssh_command

cd ../ansible
cp inventory.ini.example inventory.ini
# edit inventory.ini: fill in ansible_host and ansible_ssh_private_key_file
# from the terraform outputs above

ansible-playbook playbook.yml
```

The playbook installs nginx (from the official nginx.org repo — Rocky's
own AppStream package is a very old 1.20.1), Go, and jq; generates the
shared cert; deploys `nginx-pqc` and `nginx-classic` as independent
systemd services on ports 8443/9443; sets the SELinux contexts Rocky 9's
enforcing policy requires (skipping this silently breaks nginx reading
the cert/content — the playbook doesn't skip it); builds the bench binary
from source; and runs the same sanity checks (TLS group negotiation) that
`scripts/run-benchmark.sh` runs for the container path.

Then, on the instance:

```sh
ssh -i $(terraform -chdir=../terraform output -raw private_key_path) \
  rocky@$(terraform -chdir=../terraform output -raw public_ip)

sudo /opt/nginx-pqc-perf-test/run-benchmark.sh
cat /opt/nginx-pqc-perf-test/results/summary.md
```

Or fetch results back to your machine instead of reading them over SSH:

```sh
scp -i <key> rocky@<ip>:/opt/nginx-pqc-perf-test/results/summary.md .
```

## Gotchas

- **Key pairs and regions**: the generated key pair lives in whatever
  `var.region` you deployed to (default `us-east-1`). If you point
  Ansible/SSH at the wrong region's IP with the wrong key you'll just get
  a connection failure, not a helpful error.
- **Native results aren't directly comparable to the container-path
  numbers** in the repo root — different network path (real loopback vs.
  a container bridge network), different nginx version, no container
  runtime overhead. This deployment exists to measure PQC overhead
  without a container as a possible confound, not to produce numbers you
  cross-compare against the Docker/Podman results.
- **Cost**: this creates a real, billed EC2 instance plus an EBS volume.
  `terraform destroy` when you're done.

## Cleanup

```sh
cd terraform
terraform destroy -var="allowed_ssh_cidr=YOUR_IP/32"
```
