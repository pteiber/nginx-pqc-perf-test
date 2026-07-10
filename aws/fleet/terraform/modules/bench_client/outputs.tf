output "public_ip" {
  description = "Public IP of the bench client (SSH in here to run the fleet benchmark)."
  value       = aws_instance.client.public_ip
}

output "private_ip" {
  description = "Private IP of the bench client."
  value       = aws_instance.client.private_ip
}
