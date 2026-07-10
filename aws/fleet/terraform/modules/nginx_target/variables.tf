variable "name" {
  description = "Short name for this target (the nginx_targets map key), used in the Name tag."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for this nginx target. The CPU architecture is auto-derived from it unless ami_architecture is set."
  type        = string
}

variable "ami_architecture" {
  description = "Optional override for the CPU architecture used to look up the Rocky Linux 9 AMI (\"x86_64\" or \"arm64\"). Leave null to auto-derive from the instance type's architecture as reported by AWS."
  type        = string
  default     = null

  validation {
    condition     = var.ami_architecture == null ? true : contains(["x86_64", "arm64"], var.ami_architecture)
    error_message = "ami_architecture must be null, \"x86_64\", or \"arm64\"."
  }
}

variable "subnet_id" {
  description = "Shared subnet to launch into."
  type        = string
}

variable "security_group_id" {
  description = "Target security group ID."
  type        = string
}

variable "key_name" {
  description = "Name of the shared EC2 key pair."
  type        = string
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB."
  type        = number
}

variable "tags" {
  description = "Common tags applied to all resources."
  type        = map(string)
}
