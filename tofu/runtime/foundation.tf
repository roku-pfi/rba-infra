data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "foundation/terraform.tfstate"
    region = var.region
  }
}

locals {
  f            = data.terraform_remote_state.foundation.outputs
  cluster_name = local.f.cluster_name
}

data "aws_subnet" "public" {
  for_each = toset(local.f.public_subnet_ids)
  id       = each.value
}
