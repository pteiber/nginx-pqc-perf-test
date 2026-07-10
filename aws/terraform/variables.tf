variable "region" {
  description = "AWS region to deploy into. The Rocky Linux 9 Marketplace subscription and the generated key pair are both tied to this region."
  type        = string
  default     = "us-east-2"
}

variable "instance_type" {
  description = <<-EOT
    EC2 instance type for the benchmark VM. No default size was chosen up
    front, so this is fully overridable - but note the default below is a
    deliberate choice, not a placeholder: this is a CPU-bound crypto
    benchmark, so a fixed-performance type is used rather than a
    burstable T-series (t3.*, t4g.*) type, since burst-credit exhaustion
    would silently throttle the instance mid-run and skew the very
    numbers this benchmark exists to measure. If you do pick a T-series
    type anyway, expect handshake-rate numbers to degrade over long runs.
    The CPU architecture (x86_64 vs arm64) is auto-derived from this value,
    so a Graviton family - e.g. c9g.large (Graviton5), c8g.*, m7g.*, r8g.* -
    automatically selects the matching arm64 Rocky Linux 9 AMI. No need to
    also set ami_architecture unless you want to override the heuristic.
  EOT
  type        = string
  default     = "c6i.large"
}

variable "ami_architecture" {
  description = "Override for the CPU architecture used to look up the Rocky Linux 9 AMI (\"x86_64\" or \"arm64\"). Leave null (the default) to auto-derive it from the instance type's architecture as reported by AWS - a Graviton family like c9g.large resolves to arm64, everything else to x86_64. Rarely needed; if set, it must match the instance type's architecture or terraform plan fails."
  type        = string
  default     = null

  validation {
    condition     = var.ami_architecture == null ? true : contains(["x86_64", "arm64"], var.ami_architecture)
    error_message = "ami_architecture must be null, \"x86_64\", or \"arm64\"."
  }
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into the instance on port 22, e.g. \"203.0.113.4/32\" for a single IP. Required with no default on purpose - forces a conscious choice instead of silently defaulting to the whole internet."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.allowed_ssh_cidr))
    error_message = "allowed_ssh_cidr must be a valid CIDR block, e.g. 203.0.113.4/32."
  }
}

variable "expose_benchmark_ports" {
  description = "If true, also open 8443 and 9443 to allowed_ssh_cidr so you can run manual openssl s_client checks against the benchmark targets from outside the VM. The benchmark itself only ever talks to localhost, so this defaults to false to keep the instance's exposed surface minimal."
  type        = bool
  default     = false
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB."
  type        = number
  default     = 20
}

variable "owner" {
  description = "Owner tag applied to all created resources."
  type        = string
}

variable "email" {
  description = "Contact email tag applied to all created resources."
  type        = string
}
