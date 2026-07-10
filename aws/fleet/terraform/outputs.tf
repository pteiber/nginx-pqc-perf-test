output "client_public_ip" {
  description = "Public IP of the bench client."
  value       = module.bench_client.public_ip
}

output "client_ssh_command" {
  description = "Ready-to-copy SSH command for the bench client."
  value       = "ssh -i ${local_sensitive_file.private_key.filename} ec2-user@${module.bench_client.public_ip}"
}

output "targets" {
  description = "Map of target name -> {public_ip, private_ip, instance_type, architecture}."
  value       = local.targets_for_inventory
}

output "availability_zone" {
  description = "The single AZ the whole fleet was placed in."
  value       = module.network.az
}

output "inventory_path" {
  description = "Path to the generated Ansible inventory."
  value       = local.inventory_path
}

output "run_benchmark_hint" {
  description = "How to run the consolidated benchmark once provisioning is done."
  value       = "SSH to the client (client_ssh_command), then: /opt/nginx-pqc-perf-test/run-fleet-benchmark.sh && cat /opt/nginx-pqc-perf-test/results/summary.md"
}

output "marketplace_reminder" {
  description = "Reminder about the one-time manual prerequisite for the Rocky Linux 9 targets."
  value       = "If apply failed with OptInRequired: accept the Rocky Linux 9 Marketplace subscription for this AWS account/region via the AWS Console first, then re-run apply. See aws/README.md."
}
