# One NAT gateway, in the first public subnet: the nodes pull images and reach
# AWS APIs through it. One is enough for a demo (ADR-0031); an AZ outage would
# cut egress, not the service already running.

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "rokusec-nat" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = local.f.public_subnet_ids[0]
  tags          = { Name = "rokusec" }
}

# The foundation's private route table has no default route on purpose;
# destroying this stack removes it again.
resource "aws_route" "private_default" {
  route_table_id         = local.f.private_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}
