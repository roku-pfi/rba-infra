output "cluster_name" {
  value = module.eks.cluster_name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --profile rokusec --alias rokusec"
}

output "trusted_proxy_cidrs" {
  description = "The ALB's subnets: the IdP's TRUSTED_PROXY_CIDRS (C-2)."
  value       = join(",", [for s in data.aws_subnet.public : s.cidr_block])
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "valkey_endpoint" {
  value = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "seed_password_suffix" {
  description = "Seeded users sign in with <local part>-<this>."
  value       = random_password.seed_suffix.result
  sensitive   = true
}

output "grafana_admin_password" {
  value     = random_password.grafana.result
  sensitive = true
}

output "simulation_secret" {
  description = "Header X-RokuSec-Simulation-Secret for POST /simulation/ticket."
  value       = random_password.simulation.result
  sensitive   = true
}

output "presenter_secret" {
  description = "Password of the presenter panel at https://<bank>/presenter."
  value       = random_password.presenter.result
  sensitive   = true
}
