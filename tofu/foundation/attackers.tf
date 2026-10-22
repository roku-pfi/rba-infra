# Attacker Lambdas (I-6, ADR-0035): one small function per region, each running
# the IdP login from a real foreign AWS address. Free while idle, so they live in
# the permanent stack. The presenter panel (D-1) calls them through their
# function URLs with a shared secret; without it they answer 404.

locals {
  attacker_regions = {
    "ap-northeast-1" = "Tokio"
    "eu-central-1"   = "Fráncfort"
    "sa-east-1"      = "São Paulo"
  }
}

variable "attacker_regions_enabled" {
  description = "Set false to remove the attacker Lambdas."
  type        = bool
  default     = true
}

resource "random_password" "attacker" {
  length  = 40
  special = false
}

data "archive_file" "attacker" {
  type        = "zip"
  source_file = "${path.module}/../../attacker/handler.py"
  output_path = "${path.module}/.build/attacker.zip"
}

data "aws_iam_policy_document" "attacker_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "attacker" {
  name               = "rokusec-attacker"
  assume_role_policy = data.aws_iam_policy_document.attacker_trust.json
}

resource "aws_iam_role_policy_attachment" "attacker_logs" {
  role       = aws_iam_role.attacker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "attacker" {
  for_each          = var.attacker_regions_enabled ? local.attacker_regions : {}
  region            = each.key
  name              = "/aws/lambda/rokusec-attacker"
  retention_in_days = 7
}

resource "aws_lambda_function" "attacker" {
  for_each         = var.attacker_regions_enabled ? local.attacker_regions : {}
  region           = each.key
  function_name    = "rokusec-attacker"
  description      = "RokuSec demo attacker (${each.value}): IdP login from this region"
  role             = aws_iam_role.attacker.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.attacker.output_path
  source_code_hash = data.archive_file.attacker.output_base64sha256
  memory_size      = 128
  # Up to 20 attempts with a pause between them, each with an 8 s timeout.
  timeout = 120

  environment {
    variables = {
      IDP_URL         = "https://${aws_cloudfront_distribution.surface["auth"].domain_name}"
      ATTACKER_SECRET = random_password.attacker.result
    }
  }

  depends_on = [aws_cloudwatch_log_group.attacker, aws_iam_role_policy_attachment.attacker_logs]
}

resource "aws_lambda_function_url" "attacker" {
  for_each           = aws_lambda_function.attacker
  region             = each.key
  function_name      = each.value.function_name
  authorization_type = "NONE"
}

# Public function URLs need both permissions (Lambda, October 2025); the URL
# resource adds only InvokeFunctionUrl. The secret header is the real gate.
resource "aws_lambda_permission" "attacker_url_invoke" {
  for_each                 = aws_lambda_function.attacker
  region                   = each.key
  statement_id             = "FunctionURLInvokeFunction"
  action                   = "lambda:InvokeFunction"
  function_name            = each.value.function_name
  principal                = "*"
  invoked_via_function_url = true
}

output "attacker_urls" {
  description = "Function URL per region, for the presenter panel (ATTACKER_URLS)."
  value       = { for r, u in aws_lambda_function_url.attacker : r => u.function_url }
}

output "attacker_secret" {
  value     = random_password.attacker.result
  sensitive = true
}
