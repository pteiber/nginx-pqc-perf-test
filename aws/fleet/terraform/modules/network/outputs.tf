output "subnet_id" {
  description = "ID of the shared subnet all fleet hosts launch into."
  value       = aws_subnet.fleet.id
}

output "az" {
  description = "Availability zone the shared subnet lives in."
  value       = aws_subnet.fleet.availability_zone
}

output "client_security_group_id" {
  description = "Security group for the bench client."
  value       = aws_security_group.client.id
}

output "target_security_group_id" {
  description = "Security group for the nginx targets."
  value       = aws_security_group.target.id
}
