# OpenTofu — RokuSec on AWS

The cloud deployment of [ADR-0031](../../docs/decisions/0031-aws-eks-managed-data-plane.md).
OpenTofu (`tofu`) rather than Terraform: same language and providers, open-source
licence, and installable from Homebrew (`brew install opentofu`).

| Stack | Lifetime | What | Idle cost |
|---|---|---|---|
| `bootstrap/` | once | S3 bucket for the other stacks' state (local state) | ~0 |
| `foundation/` | permanent | VPC, subnets, S3 endpoint, ECR, CloudFront ×3, GitHub OIDC role, budget | ≈ US$1/month |
| `runtime/` | per session | NAT, EKS, RDS, ElastiCache, controllers, Helm releases | 0 once destroyed |

All commands use the SSO profile: `export AWS_PROFILE=rokusec` (log in with
`aws sso login --profile rokusec`).

## First time

```bash
cd bootstrap
tofu init && tofu apply                       # creates rokusec-tofu-state-<account>

cd ../foundation
cp terraform.tfvars.example terraform.tfvars  # set budget_email
tofu init -backend-config="bucket=rokusec-tofu-state-$(aws sts get-caller-identity --query Account --output text)"
tofu apply
tofu output hosts                             # the three https://*.cloudfront.net names
```

CloudFront distributions take a few minutes to deploy. Until the runtime stack
exists they point at a name that does not resolve and answer 502.

## Each session (runtime)

```bash
cd runtime
cp terraform.tfvars.example terraform.tfvars   # state_bucket
tofu init -backend-config="bucket=rokusec-tofu-state-$(aws sts get-caller-identity --query Account --output text)"
tofu plan                                       # review first: this one costs money by the hour
tofu apply                                      # ~20 min (EKS control plane)
$(tofu output -raw kubeconfig_command)
# … session …
tofu destroy                                    # back to ≈ US$1/month
```

Creates: NAT gateway + route, EKS (Graviton `t4g.medium` × 2, metrics-server,
Pod Identity), the AWS Load Balancer Controller, RDS PostgreSQL 16
(`db.t4g.micro`, TLS), ElastiCache Valkey 8 (`cache.t4g.micro`, TLS), every
password, the `rba-credentials` Secret the chart references
(`credentials.existingSecret`), and a Job that creates one database and login
role per service. The charts themselves are installed by I-3/I-4.

## Notes

- `*.tfstate`, `terraform.tfvars` and `.terraform/` are gitignored.
  `.terraform.lock.hcl` is committed (pins provider builds).
- The foundation's private route table has no default route on purpose; the
  runtime stack adds `0.0.0.0/0 → NAT` and removes it on destroy.
- `origin_verify_header` (sensitive output) is the secret CloudFront sends to the
  ALB; the runtime stack's ALB rules reject requests without it.
