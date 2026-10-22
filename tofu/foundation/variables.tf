variable "region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "github_org" {
  description = "GitHub organisation whose repos may push images through OIDC."
  type        = string
  default     = "roku-pfi"
}

variable "budget_email" {
  description = "Address that receives the AWS Budgets alerts. Set in terraform.tfvars (gitignored)."
  type        = string
}

variable "budget_monthly_usd" {
  description = "Monthly cost budget. Alerts at 50/80/100 % actual and 100 % forecast."
  type        = number
  default     = 30
}

variable "origin_domain" {
  description = <<-EOT
    Where CloudFront sends traffic: the ALB's DNS name while the runtime stack
    is up. `make up` re-applies this stack with the new ALB name; while the
    runtime is down the distributions point at a name that does not resolve and
    answer 502.
  EOT
  type        = string
  default     = "origin-not-deployed.rokusec.invalid"
}

variable "image_repositories" {
  description = "One ECR repository per deployable image."
  type        = list(string)
  default = [
    "rba-decision-service",
    "rba-idp",
    "rba-event-publisher",
    "rba-profile-service",
    "rba-audit-service",
    "rba-demo-banking",
    "rba-demo-kaze",
  ]
}
