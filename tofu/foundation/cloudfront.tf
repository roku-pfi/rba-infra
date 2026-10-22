# HTTPS without a domain (ADR-0031): one distribution per public surface, each
# with a stable *.cloudfront.net name. The IdP's name is the WebAuthn RP ID.
#
# CloudFront → ALB is HTTP: ACM cannot issue a certificate for the ALB's
# *.elb.amazonaws.com name, so the origin leg cannot be HTTPS without a domain.
# The ALB is locked to CloudFront twice: its security group admits only the
# CloudFront origin-facing prefix list (runtime stack), and every origin request
# carries a secret header the ALB rules require (below).

locals {
  surfaces = {
    auth = "RokuSec IdP: hosted login, console, Grafana"
    bank = "Roku Bank (tenant)"
    kaze = "Kaze Labs (tenant)"
  }
}

resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

# Managed policies: never cache (every response is per-user), and forward the
# viewer's Host, cookies, query string and all headers — including
# CloudFront-Viewer-Address (the client IP, ADR-0032) — to the origin.
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_and_cf" {
  name = "Managed-AllViewerAndCloudFrontHeaders-2022-06"
}

resource "aws_cloudfront_distribution" "surface" {
  for_each        = local.surfaces
  enabled         = true
  comment         = "rokusec-${each.key}: ${each.value}"
  is_ipv6_enabled = true
  http_version    = "http2and3"
  # All edges: the defense audience is in Buenos Aires; the per-request price
  # difference is irrelevant at demo volume.
  price_class = "PriceClass_All"

  origin {
    origin_id   = "alb"
    domain_name = var.origin_domain

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 30
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  default_cache_behavior {
    target_origin_id         = "alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_and_cf.id
    compress                 = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
