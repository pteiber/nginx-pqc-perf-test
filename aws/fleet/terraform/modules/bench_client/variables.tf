variable "instance_type" {
  description = "EC2 instance type for the bench client. Must be an x86_64 type; the Amazon Linux 2023 AMI lookup below is amd64-only."
  type        = string
}

variable "subnet_id" {
  description = "Shared subnet to launch into."
  type        = string
}

variable "security_group_id" {
  description = "Client security group ID."
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
