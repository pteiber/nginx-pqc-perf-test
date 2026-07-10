variable "usable_azs" {
  description = "Sorted list of availability zones that offer every instance type in the fleet (client + all targets), intersected with the region's available AZs. The subnet is placed in the first one, so the whole fleet lives in a single AZ sharing one low-latency network path. Empty means no single AZ can host the whole fleet (see az_selection_error)."
  type        = list(string)
}

variable "az_selection_error" {
  description = "Precomputed, instance-type-aware error message shown at plan time when usable_azs is empty."
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH (port 22) into every host. Ansible connects from here."
  type        = string
}

variable "expose_benchmark_ports" {
  description = "If true, also open target ports 8443/9443 to allowed_ssh_cidr for manual openssl checks."
  type        = bool
}

variable "tags" {
  description = "Common tags applied to all network resources."
  type        = map(string)
}
