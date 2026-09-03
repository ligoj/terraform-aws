resource "aws_vpc" "main" {
  cidr_block           = var.cidr
  instance_tenancy     = "default"
  tags                 = local.tags
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_default_security_group" "default" {
  vpc_id  = aws_vpc.main.id
  tags    = local.tags
  ingress = []
  egress  = []
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = local.tags
}

data "aws_availability_zones" "main" {}

resource "aws_subnet" "main" {
  count                   = var.nb_subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.cidr, var.cidr_newbits, count.index)
  availability_zone       = data.aws_availability_zones.main.names[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { "Name" = "${local.name}-az${count.index}" })
  depends_on              = [aws_internet_gateway.main]
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id
  tags   = local.tags
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}
resource "aws_route_table_association" "main" {
  count          = var.nb_subnets
  subnet_id      = aws_subnet.main[count.index].id
  route_table_id = aws_route_table.main.id
}

# Private tier: hosts the internal ALB, whose authenticate-cognito action must
# reach the Cognito token endpoint on the internet - internal ALB nodes have no
# public IP, so their egress goes through the NAT gateway
resource "aws_subnet" "private" {
  count             = var.nb_subnets
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.cidr, var.cidr_newbits, var.nb_subnets + count.index)
  availability_zone = data.aws_availability_zones.main.names[count.index]
  tags              = merge(local.tags, { "Name" = "${local.name}-private-az${count.index}" })
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { "Name" = "${local.name}-nat" })
}

# Single-AZ on purpose: only the ALB token exchanges use it, and a second
# gateway would double a cost that a rare AZ outage does not justify here
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.main[0].id
  tags          = local.tags
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { "Name" = "${local.name}-private" })
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}
resource "aws_route_table_association" "private" {
  count          = var.nb_subnets
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
