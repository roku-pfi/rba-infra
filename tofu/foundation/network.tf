# One VPC, two AZs, a public and a private subnet in each (ADR-0031).
#
# Public:  the ALB, and the NAT gateway (created by the runtime stack).
# Private: EKS nodes, RDS, ElastiCache. No route to the internet gateway.
#
# The private route tables live here with no default route; the runtime stack
# adds 0.0.0.0/0 → NAT when it creates the NAT gateway, and removes it on
# destroy. Nothing in a private subnet needs the internet while the runtime is
# down, because nothing runs there.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # /20 public (ALB + NAT need few addresses); /19 private, because the VPC CNI
  # gives every pod a VPC address.
  public_cidrs  = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1)]
  private_cidrs = [cidrsubnet(var.vpc_cidr, 3, 4), cidrsubnet(var.vpc_cidr, 3, 5)]

  cluster_name = "rokusec"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "rokusec" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "rokusec" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
  tags = {
    Name                                          = "rokusec-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags = {
    Name                                          = "rokusec-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "rokusec-public" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "rokusec-private" }
  # 0.0.0.0/0 → NAT is an aws_route in the runtime stack.
  lifecycle {
    ignore_changes = [route]
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# S3 gateway endpoint: free, and keeps image-layer pulls from ECR (stored in S3)
# off the NAT gateway's per-GB charge.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "rokusec-s3" }
}
