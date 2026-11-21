# A small, dedicated network for Jenkins: one public subnet, no NAT gateway (saves ~$32/month).
# Nothing can connect IN (no inbound rules); the instance only makes OUTBOUND calls.

resource "aws_vpc" "jenkins" {
  #checkov:skip=CKV2_AWS_11:Flow logs skipped for a single-instance CI VPC with no inbound rules (cost/scope); revisit in hardening
  cidr_block           = "10.20.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "${local.name}-vpc"
  }
}

# Lock down the VPC's default security group so nothing accidentally uses an open one
resource "aws_default_security_group" "jenkins" {
  vpc_id = aws_vpc.jenkins.id
}

resource "aws_internet_gateway" "jenkins" {
  vpc_id = aws_vpc.jenkins.id
  tags = {
    Name = "${local.name}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.jenkins.id
  cidr_block              = "10.20.0.0/26"
  availability_zone       = "us-east-1a" # pinned, so it can never shift and force Jenkins to be rebuilt
  map_public_ip_on_launch = false        # the instance asks for its public IP explicitly
  tags = {
    Name = "${local.name}-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.jenkins.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.jenkins.id
  }
  tags = {
    Name = "${local.name}-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# NO inbound rules at all. Access is through SSM, which the instance reaches outbound over HTTPS.
resource "aws_security_group" "jenkins" {
  name        = "${local.name}-sg"
  description = "Jenkins: no inbound; outbound HTTPS/HTTP only"
  vpc_id      = aws_vpc.jenkins.id

  egress {
    description = "HTTPS: GitHub, Docker Hub, AWS APIs (SSM, STS, Terraform)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP: OS package repositories"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-sg"
  }
}