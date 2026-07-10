# One Rocky Linux 9 nginx target. Mirrors the single-host mode's instance
# (aws/single/terraform/main.tf) but leaner: it only runs nginx-pqc and
# nginx-classic; the bench tool lives on the separate client. Networking
# (VPC/subnet/SG/key) is supplied by the root module so every target in
# the fleet shares one subnet.
#
# Rocky Linux 9 is Marketplace-only (owner account 679593333241); the AWS
# account must accept the "Rocky Linux 9" subscription once per account,
# or apply fails with OptInRequired. See aws/README.md.
locals {
  # Auto-derive arch from what AWS reports the instance type supports,
  # rather than guessing from the name; arm64 iff AWS lists it (covers
  # Graviton families the name can't reveal). Overridable via
  # ami_architecture for the rare escape-hatch case.
  derived_architecture = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"
  ami_architecture     = coalesce(var.ami_architecture, local.derived_architecture)
}

data "aws_ec2_instance_type" "selected" {
  instance_type = var.instance_type
}

data "aws_ami" "rocky9" {
  most_recent = true
  owners      = ["679593333241"]

  filter {
    name   = "name"
    values = ["Rocky-9-EC2-LVM-*"]
  }

  filter {
    name   = "architecture"
    values = [local.ami_architecture]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "target" {
  ami                    = data.aws_ami.rocky9.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
  }

  metadata_options {
    http_tokens = "required" # enforce IMDSv2
  }

  # Catch an architecture mismatch at plan time rather than as an
  # InvalidParameterValue at apply time. Only trips when ami_architecture
  # is overridden to something the instance type doesn't support; the
  # auto-derived value comes from this same list, so it can't.
  lifecycle {
    precondition {
      condition     = contains(data.aws_ec2_instance_type.selected.supported_architectures, local.ami_architecture)
      error_message = "ami_architecture \"${local.ami_architecture}\" does not match instance_type \"${var.instance_type}\" (supports ${join(", ", data.aws_ec2_instance_type.selected.supported_architectures)}). Remove the ami_architecture override to auto-derive it, or pick an instance_type of the matching architecture."
    }
  }

  tags = merge(var.tags, {
    Name = "nginx-pqc-perf-test-target-${var.name}"
    role = "nginx-target"
  })
}
