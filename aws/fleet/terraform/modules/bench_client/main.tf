# The single bench client. Amazon Linux 2023, amd64 ("any basic amd64
# Amazon Linux host will work"): it just needs Go (installed from the
# official tarball by Ansible, to guarantee the >= 1.24 that
# X25519MLKEM768 requires), jq, and SSH access to the targets. It drives
# every benchmark over the network and consolidates the results.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
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

resource "aws_instance" "client" {
  ami                    = data.aws_ami.al2023.id
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

  tags = merge(var.tags, {
    Name = "nginx-pqc-perf-test-client"
    role = "bench-client"
  })
}
