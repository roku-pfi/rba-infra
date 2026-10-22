variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  description = "The bootstrap bucket, to read the foundation stack's outputs."
  type        = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.33"
}

variable "node_instance_type" {
  description = "Graviton (arm64). Images are multi-arch, so t3.medium also works."
  type        = string
  default     = "t4g.medium"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "cache_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "app_namespace" {
  description = "Namespace of the rba chart; the credentials Secret is created there."
  type        = string
  default     = "rba"
}

variable "service_databases" {
  description = "One database and one login role per service (ADR-0010 semantics)."
  type        = list(string)
  default     = ["rba_idp", "rba_decision", "rba_profile", "rba_audit"]
}
