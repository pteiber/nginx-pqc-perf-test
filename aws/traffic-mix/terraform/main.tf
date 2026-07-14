# Traffic-mix mode root module. Wires a shared network, N nginx target
# hosts (one per nginx_targets entry), and a single client that drives a
# realistic mixed workload (HTTP request rate + TLS handshake rate +
# session-resumption percentage + random response sizes) over the network
# and consolidates the results. After the instances come up it renders
# the Ansible inventory and (unless run_ansible = false) runs the playbook
# automatically.
#
# This is the workload sibling of the handshake-only fleet mode under
# aws/fleet/; the two share no Terraform or Ansible (see aws/README.md).
# The single-host mode lives separately under aws/single/.

locals {
  common_tags = {
    owner   = var.owner
    email   = var.email
    project = "nginx-pqc-perf-test"
  }

  # Every distinct instance type in the fleet: the client plus each
  # target. The shared subnet must sit in an AZ that offers all of them.
  all_instance_types = toset(concat(
    [var.client_instance_type],
    [for t in var.nginx_targets : t.instance_type],
  ))
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Which AZs offer each instance type in the fleet. Used to place the one
# shared subnet in an AZ that can actually run every host (newly launched
# families are offered in only a subset of AZs).
data "aws_ec2_instance_type_offerings" "by_az" {
  for_each = local.all_instance_types

  filter {
    name   = "instance-type"
    values = [each.value]
  }

  location_type = "availability-zone"
}

locals {
  # Intersect the region's available AZs with the AZ set of every
  # instance type; the result is the AZs that can host the whole fleet.
  az_sets = concat(
    [toset(data.aws_availability_zones.available.names)],
    [for t in local.all_instance_types : toset(data.aws_ec2_instance_type_offerings.by_az[t].locations)],
  )
  usable_azs = sort(setintersection(local.az_sets...))

  az_selection_error = "No single availability zone in region \"${var.region}\" offers every instance type in the fleet (${join(", ", local.all_instance_types)}). Mixing a brand-new family (e.g. c9g) with others can leave no overlapping AZ. Pick instance types with overlapping AZ coverage, or change the region."
}

# --- shared SSH key (generated per-apply) -----------------------------------
# Written locally (generated/, gitignored) and, as a consequence of using
# tls_private_key, also stored in Terraform state; treat local .tfstate as
# sensitive. Ansible copies this same key onto the client so it can SSH
# the targets to run the CPU/mem poller.
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "generated" {
  key_name   = "nginx-pqc-perf-test-traffic-mix-${substr(md5(tls_private_key.ssh.public_key_openssh), 0, 8)}"
  public_key = tls_private_key.ssh.public_key_openssh

  tags = merge(local.common_tags, { Name = "nginx-pqc-perf-test-traffic-mix" })
}

resource "local_sensitive_file" "private_key" {
  filename        = "${path.module}/generated/nginx-pqc-perf-test-traffic-mix.pem"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}

# --- network ----------------------------------------------------------------
module "network" {
  source = "./modules/network"

  usable_azs             = local.usable_azs
  az_selection_error     = local.az_selection_error
  allowed_ssh_cidr       = var.allowed_ssh_cidr
  expose_benchmark_ports = var.expose_benchmark_ports
  tags                   = local.common_tags
}

# --- nginx targets (one per map entry) --------------------------------------
module "nginx_target" {
  source   = "./modules/nginx_target"
  for_each = var.nginx_targets

  name                = each.key
  instance_type       = each.value.instance_type
  ami_architecture    = each.value.ami_architecture
  subnet_id           = module.network.subnet_id
  security_group_id   = module.network.target_security_group_id
  key_name            = aws_key_pair.generated.key_name
  root_volume_size_gb = var.root_volume_size_gb
  tags                = local.common_tags
}

# --- bench client -----------------------------------------------------------
module "bench_client" {
  source = "./modules/bench_client"

  instance_type       = var.client_instance_type
  subnet_id           = module.network.subnet_id
  security_group_id   = module.network.client_security_group_id
  key_name            = aws_key_pair.generated.key_name
  root_volume_size_gb = var.root_volume_size_gb
  tags                = local.common_tags
}

# --- Ansible inventory ------------------------------------------------------
# Ansible SSHes to public IPs from the operator's workstation; the client
# benchmarks and polls the targets over their private IPs (intra-VPC), so
# both are carried into the inventory.
locals {
  inventory_path = "${path.module}/../ansible/inventory.ini"

  targets_for_inventory = {
    for name, t in module.nginx_target : name => {
      public_ip     = t.public_ip
      private_ip    = t.private_ip
      instance_type = t.instance_type
      architecture  = t.architecture
    }
  }
}

resource "local_file" "inventory" {
  filename = local.inventory_path
  content = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    targets              = local.targets_for_inventory
    client_public_ip     = module.bench_client.public_ip
    ssh_private_key_file = abspath(local_sensitive_file.private_key.filename)
  })
  file_permission = "0644"
}

# --- run Ansible automatically ----------------------------------------------
# terraform_data is a built-in resource (no extra provider). It re-runs
# whenever any instance ID changes. SSH readiness is handled by a
# wait_for_connection task at the top of the target play, so there's no
# sleep hack here.
resource "terraform_data" "ansible" {
  count = var.run_ansible ? 1 : 0

  triggers_replace = {
    client_id  = module.bench_client.public_ip
    target_ids = join(",", [for t in module.nginx_target : t.private_ip])
    inventory  = local_file.inventory.content
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible"
    command     = "ansible-playbook -i inventory.ini site.yml"
    environment = {
      ANSIBLE_HOST_KEY_CHECKING = "False"
    }
  }

  depends_on = [
    module.nginx_target,
    module.bench_client,
    local_file.inventory,
  ]
}
