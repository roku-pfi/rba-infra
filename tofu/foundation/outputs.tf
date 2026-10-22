# Read by the runtime stack (terraform_remote_state) and by the scripts.

output "region" {
  value = var.region
}

output "cluster_name" {
  value = local.cluster_name
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "private_route_table_id" {
  value = aws_route_table.private.id
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "github_ci_role_arn" {
  value = aws_iam_role.github_ci.arn
}

output "hosts" {
  description = "Stable public host per surface. auth = WebAuthn RP ID."
  value       = { for k, d in aws_cloudfront_distribution.surface : k => d.domain_name }
}

output "distribution_ids" {
  value = { for k, d in aws_cloudfront_distribution.surface : k => d.id }
}

output "origin_verify_header" {
  value     = random_password.origin_verify.result
  sensitive = true
}
