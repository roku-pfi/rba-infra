# Every secret is generated here and lands in one Kubernetes Secret, which the
# chart references with `credentials.existingSecret` (ADR-0031, C-4). They live
# in this stack's state (encrypted S3) and in the cluster, never in git.

resource "random_password" "service" {
  for_each = toset(var.service_databases)
  length   = 32
  special  = false
}

resource "random_password" "rabbitmq" {
  length  = 32
  special = false
}

# Seeded users' passwords are "<local part>-<suffix>" (rba_idp.seed).
resource "random_password" "seed_suffix" {
  length  = 16
  special = false
}

resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "random_password" "simulation" {
  length  = 48
  special = false
}

# The presenter panel's password (D-1). Only scripts/aws-up.sh hands it to the bank.
resource "random_password" "presenter" {
  length  = 24
  special = false
}

resource "kubernetes_namespace_v1" "app" {
  metadata { name = var.app_namespace }
  depends_on = [module.eks]
}

locals {
  db_host = aws_db_instance.main.address
  # RDS PostgreSQL 16 requires TLS (rds.force_ssl defaults to 1).
  db_url = {
    for db in var.service_databases :
    db => "postgresql+psycopg://${db}:${random_password.service[db].result}@${local.db_host}:5432/${db}?sslmode=require"
  }
  redis_url = "rediss://${aws_elasticache_replication_group.main.primary_endpoint_address}:6379/0"
}

resource "kubernetes_secret_v1" "credentials" {
  metadata {
    name      = "rba-credentials"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    RABBITMQ_DEFAULT_USER    = "rba"
    RABBITMQ_DEFAULT_PASS    = random_password.rabbitmq.result
    RABBITMQ_URL             = "amqp://rba:${random_password.rabbitmq.result}@rabbitmq:5672/"
    REDIS_URL                = local.redis_url
    IDP_DATABASE_URL         = local.db_url["rba_idp"]
    DECISION_DATABASE_URL    = local.db_url["rba_decision"]
    PROFILE_DATABASE_URL     = local.db_url["rba_profile"]
    AUDIT_DATABASE_URL       = local.db_url["rba_audit"]
    IDP_SEED_PASSWORD_SUFFIX = random_password.seed_suffix.result
    SIMULATION_SECRET        = random_password.simulation.result
    GRAFANA_ADMIN_PASSWORD   = random_password.grafana.result
  }
}

# ---------------------------------------------------------------- database bootstrap
# RDS is private, so the databases and their roles are created from inside the
# cluster: one Job, as the master user, idempotent. The services' own init Jobs
# (C-4) then create their tables.

resource "kubernetes_secret_v1" "db_admin" {
  metadata {
    name      = "rba-db-admin"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = merge(
    {
      PGHOST     = local.db_host
      PGUSER     = aws_db_instance.main.username
      PGPASSWORD = random_password.db_master.result
      PGDATABASE = "postgres"
      PGSSLMODE  = "require"
    },
    { for db in var.service_databases : "PW_${upper(db)}" => random_password.service[db].result },
  )
}

locals {
  # Role first (with the password from the Secret), then grant it to the
  # master so it may own a database, then the database if missing.
  bootstrap_sql = join("\n", flatten([
    for db in var.service_databases : [
      "SELECT format('CREATE ROLE %I LOGIN', '${db}') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${db}')\\gexec",
      "ALTER ROLE ${db} WITH LOGIN PASSWORD :'pw_${db}';",
      "GRANT ${db} TO CURRENT_USER;",
      "SELECT format('CREATE DATABASE %I OWNER %I', '${db}', '${db}') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}')\\gexec",
    ]
  ]))
  bootstrap_vars = join(" ", [for db in var.service_databases : "-v pw_${db}=\"$PW_${upper(db)}\""])
}

resource "kubernetes_job_v1" "db_bootstrap" {
  metadata {
    name      = "rba-db-bootstrap"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    backoff_limit = 6
    template {
      metadata {}
      spec {
        restart_policy = "Never"
        container {
          name    = "psql"
          image   = "postgres:16-alpine"
          command = ["sh", "-c"]
          args = [<<-EOT
            set -e
            until pg_isready -q; do echo waiting for RDS; sleep 3; done
            cat > /tmp/bootstrap.sql <<'SQL'
            ${local.bootstrap_sql}
            SQL
            psql -v ON_ERROR_STOP=1 ${local.bootstrap_vars} -f /tmp/bootstrap.sql
          EOT
          ]
          env_from {
            secret_ref { name = kubernetes_secret_v1.db_admin.metadata[0].name }
          }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts {
    create = "10m"
  }
}
