# Rocky Linux 9 is only published to AWS Marketplace, not the free AMI
# catalog. Owner account 679593333241 is the Marketplace account Rocky
# Linux publishes under. IMPORTANT: your AWS account must accept the
# Marketplace subscription terms for "Rocky Linux 9" via the AWS Console
# at least once before Terraform can launch instances from this AMI -
# otherwise `apply` fails with an OptInRequired error. See ../README.md.
data "aws_ami" "rocky9" {
  most_recent = true
  owners      = ["679593333241"]

  filter {
    name   = "name"
    values = ["Rocky-9-EC2-Base-*"]
  }

  filter {
    name   = "architecture"
    values = [var.ami_architecture]
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

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Generated fresh per-apply so there's nothing to pre-provision. The
# private key is written locally (generated/, gitignored) and also lands
# in Terraform state as a result of using tls_private_key - see
# ../README.md for the tradeoffs of that vs. bringing your own key pair.
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "generated" {
  key_name   = "nginx-pqc-perf-test-${substr(md5(tls_private_key.ssh.public_key_openssh), 0, 8)}"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  filename        = "${path.module}/generated/nginx-pqc-perf-test.pem"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}

resource "aws_security_group" "benchmark" {
  name_prefix = "nginx-pqc-perf-test-"
  description = "nginx-pqc-perf-test benchmark VM"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  dynamic "ingress" {
    for_each = var.expose_benchmark_ports ? [8443, 9443] : []
    content {
      description = "nginx-pqc-perf-test manual verification"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [var.allowed_ssh_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nginx-pqc-perf-test"
  }
}

resource "aws_instance" "benchmark" {
  ami                    = data.aws_ami.rocky9.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.generated.key_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.benchmark.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
  }

  metadata_options {
    http_tokens = "required" # enforce IMDSv2
  }

  tags = {
    Name = "nginx-pqc-perf-test"
  }
}
