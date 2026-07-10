# Rocky Linux 9 is only published to AWS Marketplace, not the free AMI
# catalog. Owner account 679593333241 is the Marketplace account Rocky
# Linux publishes under. IMPORTANT: your AWS account must accept the
# Marketplace subscription terms for "Rocky Linux 9" via the AWS Console
# at least once before Terraform can launch instances from this AMI -
# otherwise `apply` fails with an OptInRequired error. See ../README.md.
locals {
  # Auto-derive the CPU architecture from the instance type unless explicitly
  # overridden. This reads AWS's own supported_architectures for the type
  # (see data.aws_ec2_instance_type.selected) rather than guessing from the
  # name, so every family - including Graviton ones the name can't reveal,
  # like the old "a1" - resolves correctly. arm64 iff AWS reports it.
  derived_architecture = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"
  ami_architecture     = coalesce(var.ami_architecture, local.derived_architecture)

  # AZs in this region that actually offer the chosen instance type, intersected
  # with the region's available AZs. Newly launched families (e.g. Graviton5
  # c9g) are offered in only a subset of AZs, so blindly taking names[0] can
  # fail - pick a usable one deterministically instead.
  usable_azs = sort(setintersection(
    toset(data.aws_ec2_instance_type_offerings.by_az.locations),
    toset(data.aws_availability_zones.available.names),
  ))
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

data "aws_availability_zones" "available" {
  state = "available"
}

# Authoritative architecture for the chosen instance type, straight from AWS -
# no name-based guessing. supported_architectures is e.g. ["arm64"] for
# Graviton, ["x86_64"] (or ["i386","x86_64"]) otherwise.
data "aws_ec2_instance_type" "selected" {
  instance_type = var.instance_type
}

# Which AZs in this region offer the chosen instance type. Used to place the
# subnet in an AZ that can actually run it (see local.usable_azs).
data "aws_ec2_instance_type_offerings" "by_az" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }

  location_type = "availability-zone"
}

resource "aws_vpc" "benchmark" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name  = "nginx-pqc-perf-test"
    owner = var.owner
    email = var.email
  }
}

resource "aws_subnet" "benchmark" {
  vpc_id                  = aws_vpc.benchmark.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = local.usable_azs[0]
  map_public_ip_on_launch = true

  tags = {
    Name  = "nginx-pqc-perf-test"
    owner = var.owner
    email = var.email
  }

  # Fail at plan time with an actionable message rather than a cryptic
  # "index out of range" on usable_azs[0] when the chosen instance type is
  # offered in no AZ of this region (common for brand-new families like c9g).
  lifecycle {
    precondition {
      condition     = length(local.usable_azs) > 0
      error_message = "instance_type \"${var.instance_type}\" is not offered in any availability zone of region \"${var.region}\". Pick a different instance_type or region (e.g. c9g is in us-east-1, us-east-2, us-west-2, eu-central-1)."
    }
  }
}

resource "aws_internet_gateway" "benchmark" {
  vpc_id = aws_vpc.benchmark.id

  tags = {
    Name  = "nginx-pqc-perf-test"
    owner = var.owner
    email = var.email
  }
}

resource "aws_route_table" "benchmark" {
  vpc_id = aws_vpc.benchmark.id

  route {
    cidr_block      = "0.0.0.0/0"
    gateway_id      = aws_internet_gateway.benchmark.id
  }

  tags = {
    Name  = "nginx-pqc-perf-test"
    owner = var.owner
    email = var.email
  }
}

resource "aws_route_table_association" "benchmark" {
  subnet_id      = aws_subnet.benchmark.id
  route_table_id = aws_route_table.benchmark.id
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

  tags = {
    Name  = "nginx-pqc-perf-test"
    owner = var.owner
    email = var.email
  }
}

resource "local_sensitive_file" "private_key" {
  filename        = "${path.module}/generated/nginx-pqc-perf-test.pem"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}

resource "aws_security_group" "benchmark" {
  name_prefix = "nginx-pqc-perf-test-"
  description = "nginx-pqc-perf-test benchmark VM"
  vpc_id      = aws_vpc.benchmark.id

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
    Name  = "nginx-pqc-perf-test"
    owner = var.owner
    email = var.email
  }
}

resource "aws_instance" "benchmark" {
  ami                    = data.aws_ami.rocky9.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.generated.key_name
  subnet_id              = aws_subnet.benchmark.id
  vpc_security_group_ids = [aws_security_group.benchmark.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
  }

  metadata_options {
    http_tokens = "required" # enforce IMDSv2
  }

  # Catch an architecture mismatch at plan time instead of letting it surface
  # as an InvalidParameterValue from RunInstances at apply time. Only trips
  # when ami_architecture is overridden to something the instance type doesn't
  # support; the auto-derived value comes from this same list, so it can't.
  lifecycle {
    precondition {
      condition     = contains(data.aws_ec2_instance_type.selected.supported_architectures, local.ami_architecture)
      error_message = "ami_architecture \"${local.ami_architecture}\" does not match instance_type \"${var.instance_type}\" (supports ${join(", ", data.aws_ec2_instance_type.selected.supported_architectures)}). Remove the ami_architecture override to auto-derive it, or set an instance_type of the matching architecture."
    }
  }

  tags = {
    Name  = "nginx-pqc-perf-test"
    owner = var.owner
    email = var.email
  }
}
