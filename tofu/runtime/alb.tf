# The ALB itself is created by the Load Balancer Controller from the charts'
# Ingresses (I-3). Its security group is made here, so it is locked down from
# the first second: port 80, only from CloudFront's origin-facing addresses.
# Requests that skip CloudFront are also refused by the ALB rules, which
# require the X-Origin-Verify header CloudFront adds (foundation stack).

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "rokusec-alb"
  description = "ALB: HTTP from CloudFront only"
  vpc_id      = local.f.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_vpc" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = local.f.vpc_cidr
  ip_protocol       = "-1"
}
