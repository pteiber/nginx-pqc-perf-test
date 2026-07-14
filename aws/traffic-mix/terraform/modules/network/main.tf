# Shared VPC/subnet/gateway for the whole fleet, plus the two security
# groups that encode the traffic model:
#   operator --SSH--> everything            (Ansible provisions from your workstation)
#   client   --SSH--> targets               (client runs the CPU/mem poller on each target)
#   client   --8443/9443--> targets         (client runs the handshake benchmark)
# Client and all targets share one subnet in one AZ so every measured
# handshake traverses the same minimal intra-VPC path.

resource "aws_vpc" "fleet" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "nginx-pqc-perf-test-traffic-mix" })
}

resource "aws_subnet" "fleet" {
  vpc_id                  = aws_vpc.fleet.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = var.usable_azs[0]
  map_public_ip_on_launch = true

  tags = merge(var.tags, { Name = "nginx-pqc-perf-test-traffic-mix" })

  # Fail at plan time with an actionable, instance-type-aware message
  # rather than a cryptic "index out of range" on usable_azs[0] when no
  # single AZ offers every instance type in the fleet (common when mixing
  # a brand-new family like c9g with an older one, since their AZ
  # coverage may not overlap in the chosen region).
  lifecycle {
    precondition {
      condition     = length(var.usable_azs) > 0
      error_message = var.az_selection_error
    }
  }
}

resource "aws_internet_gateway" "fleet" {
  vpc_id = aws_vpc.fleet.id

  tags = merge(var.tags, { Name = "nginx-pqc-perf-test-traffic-mix" })
}

resource "aws_route_table" "fleet" {
  vpc_id = aws_vpc.fleet.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.fleet.id
  }

  tags = merge(var.tags, { Name = "nginx-pqc-perf-test-traffic-mix" })
}

resource "aws_route_table_association" "fleet" {
  subnet_id      = aws_subnet.fleet.id
  route_table_id = aws_route_table.fleet.id
}

# --- bench client -----------------------------------------------------------
resource "aws_security_group" "client" {
  name_prefix = "nginx-pqc-traffic-mix-client-"
  description = "nginx-pqc-perf-test traffic-mix client"
  vpc_id      = aws_vpc.fleet.id

  ingress {
    description = "SSH from operator (Ansible)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "nginx-pqc-perf-test-traffic-mix-client" })
}

# --- nginx targets ----------------------------------------------------------
resource "aws_security_group" "target" {
  name_prefix = "nginx-pqc-traffic-mix-target-"
  description = "nginx-pqc-perf-test traffic-mix nginx target"
  vpc_id      = aws_vpc.fleet.id

  ingress {
    description = "SSH from operator (Ansible)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description     = "SSH from bench client (remote CPU/mem poller)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.client.id]
  }

  ingress {
    description     = "Benchmark ports from bench client"
    from_port       = 8443
    to_port         = 9443
    protocol        = "tcp"
    security_groups = [aws_security_group.client.id]
  }

  # Optional external exposure of the benchmark ports for manual
  # openssl s_client verification from the operator's workstation. The
  # client always reaches the targets via the intra-VPC rule above, so
  # this is purely additive and off by default.
  dynamic "ingress" {
    for_each = var.expose_benchmark_ports ? [8443, 9443] : []
    content {
      description = "Manual verification from operator"
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

  tags = merge(var.tags, { Name = "nginx-pqc-perf-test-traffic-mix-target" })
}
