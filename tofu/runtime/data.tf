# Managed state (ADR-0031): RDS PostgreSQL and ElastiCache for Valkey, single
# instance each, private subnets, reachable only from the EKS nodes. Both are
# destroyed with this stack: every session starts with fresh databases.

locals {
  # With the VPC CNI, pods use their node's security groups.
  workload_security_groups = [module.eks.node_security_group_id, module.eks.cluster_primary_security_group_id]
}

# ---------------------------------------------------------------- PostgreSQL

resource "aws_db_subnet_group" "main" {
  name       = "rokusec"
  subnet_ids = local.f.private_subnet_ids
}

resource "aws_security_group" "db" {
  name        = "rokusec-postgres"
  description = "PostgreSQL from the EKS workloads only"
  vpc_id      = local.f.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_workloads" {
  for_each                     = toset(local.workload_security_groups)
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "random_password" "db_master" {
  length  = 32
  special = false
}

resource "aws_db_instance" "main" {
  identifier     = "rokusec"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "postgres"
  username = "rba_admin"
  password = random_password.db_master.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  # Disposable by design: no snapshot, no backups, no deletion guard.
  skip_final_snapshot     = true
  backup_retention_period = 0
  deletion_protection     = false
  apply_immediately       = true
}

# ---------------------------------------------------------------- Valkey

resource "aws_elasticache_subnet_group" "main" {
  name       = "rokusec"
  subnet_ids = local.f.private_subnet_ids
}

resource "aws_security_group" "cache" {
  name        = "rokusec-valkey"
  description = "Valkey from the EKS workloads only"
  vpc_id      = local.f.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_workloads" {
  for_each                     = toset(local.workload_security_groups)
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "rokusec"
  description          = "Behavioural profiles (ProfileState)"
  engine               = "valkey"
  engine_version       = "8.0"
  node_type            = var.cache_node_type
  num_cache_clusters   = 1
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.cache.id]

  # TLS in transit (the client URL is rediss://); encrypted at rest.
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  apply_immediately          = true
}
