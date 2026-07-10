output "public_ip" {
  description = "Public IP (operator/Ansible SSH reaches the target here)."
  value       = aws_instance.target.public_ip
}

output "private_ip" {
  description = "Private IP (the bench client benchmarks and polls the target here, intra-VPC)."
  value       = aws_instance.target.private_ip
}

output "instance_type" {
  description = "The instance type of this target (echoed for the results table)."
  value       = var.instance_type
}

output "architecture" {
  description = "Resolved CPU architecture of this target's AMI."
  value       = local.ami_architecture
}
