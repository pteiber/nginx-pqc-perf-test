variable "region" {
  description = "AWS region to deploy into. The Rocky Linux 9 Marketplace subscription and the generated key pair are both tied to this region."
  type        = string
  default     = "us-east-2"
}

variable "nginx_targets" {
  description = <<-EOT
    The set of nginx target hosts to benchmark, keyed by a short name used
    in inventory, tags, and the results table (e.g. "c6i", "c8g"). Each
    value picks an EC2 instance type; the CPU architecture is auto-derived
    from it (a Graviton family resolves to arm64, everything else x86_64),
    so adding a host to the fleet is one map entry:

      nginx_targets = {
        c6i = { instance_type = "c6i.large" }   # amd64
        c8g = { instance_type = "c8g.large" }   # Graviton (arm64)
      }

    As with the single-host mode, prefer fixed-performance types over
    burstable T-series ones: burst-credit exhaustion would silently
    throttle a target mid-run and skew this CPU-bound crypto benchmark.
    ami_architecture is an optional per-target escape hatch; leave it unset
    to auto-derive from the instance type (see modules/nginx_target).
  EOT
  type = map(object({
    instance_type    = string
    ami_architecture = optional(string)
  }))

  validation {
    condition     = length(var.nginx_targets) > 0
    error_message = "nginx_targets must contain at least one target; the fleet exists to benchmark nginx hosts."
  }
}

variable "client_instance_type" {
  description = <<-EOT
    EC2 instance type for the single bench client host (Amazon Linux 2023,
    amd64). The client generates every handshake, so it must NOT be the
    bottleneck: if it saturates, target handshake rates converge on the
    client's ceiling instead of measuring the targets, and cross-instance
    comparisons become meaningless. Scale this up (more vCPUs) if you see
    the client pegged at 100% CPU during a run. Must be an x86_64 type;
    the Amazon Linux 2023 AMI lookup is amd64-only.
  EOT
  type        = string
  default     = "c6i.xlarge"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into every host on port 22, e.g. \"203.0.113.4/32\" for a single IP. Ansible connects from here. Required with no default on purpose, so you don't accidentally open SSH to the whole internet."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.allowed_ssh_cidr))
    error_message = "allowed_ssh_cidr must be a valid CIDR block, e.g. 203.0.113.4/32."
  }
}

variable "expose_benchmark_ports" {
  description = "If true, also open the target ports 8443 and 9443 to allowed_ssh_cidr so you can run manual openssl s_client checks from your workstation. The client always reaches the targets intra-VPC regardless; this only widens external exposure, so it defaults to false."
  type        = bool
  default     = false
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB, applied to every host (targets and client)."
  type        = number
  default     = 20
}

variable "run_ansible" {
  description = "If true (the default), Terraform runs the Ansible playbook automatically after the instances are provisioned, using the generated inventory. Set to false to provision infrastructure only and run Ansible yourself against aws/traffic-mix/ansible/inventory.ini."
  type        = bool
  default     = true
}

variable "owner" {
  description = "Owner tag applied to all created resources."
  type        = string
}

variable "email" {
  description = "Contact email tag applied to all created resources."
  type        = string
}
