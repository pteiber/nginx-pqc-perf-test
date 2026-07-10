output "public_ip" {
  description = "Public IP of the benchmark instance."
  value       = aws_instance.benchmark.public_ip
}

output "private_key_path" {
  description = "Path to the generated SSH private key."
  value       = local_sensitive_file.private_key.filename
}

output "ssh_command" {
  description = "Ready-to-copy SSH command."
  value       = "ssh -i ${local_sensitive_file.private_key.filename} rocky@${aws_instance.benchmark.public_ip}"
}

output "marketplace_reminder" {
  description = "Reminder about the one-time manual prerequisite."
  value       = "If apply failed with OptInRequired: accept the Rocky Linux 9 Marketplace subscription for this AWS account/region via the AWS Console first, then re-run apply. See ../README.md."
}
