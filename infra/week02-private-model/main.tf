# =============================================================================
# Week 2: a private path to Amazon Bedrock, and proof that it's private
# -----------------------------------------------------------------------------
#   - Interface VPC endpoint for bedrock-runtime, private DNS on, in one AZ
#     (one AZ keeps the lab cheap; production uses at least two)
#   - An IAM role that may call ONE model, and only through THIS endpoint
#     (condition aws:SourceVpce). Same credentials, wrong path = AccessDenied.
#   - The "prober" Lambda twice, with the same code and the same role:
#       prober         inside the VPC  -> should succeed through the endpoint
#       prober-outside outside the VPC -> should be denied
#
# Amazon Bedrock is a regional AWS service with a public endpoint. On AWS,
# "private" means: workloads have no internet path, traffic stays on the
# endpoint, and identity policies refuse any other path. You prove all three.
# =============================================================================

data "terraform_remote_state" "w1" {
  backend = "local"
  config  = { path = "${path.module}/../week01-landing-zone/terraform.tfstate" }
}

data "aws_caller_identity" "me" {}

locals {
  net        = data.terraform_remote_state.w1.outputs
  account_id = data.aws_caller_identity.me.account_id
}

variable "model_id" {
  description = "The approved model: Amazon Nova Lite through the Canada (ca.) cross-Region inference profile, so requests are processed only in ca-central-1 and ca-west-1. See weeks/02-private-model/README.md."
  type        = string
  default     = "ca.amazon.nova-lite-v1:0"
}

locals {
  # A ca. profile routes to the same model in both Canadian Regions. IAM must
  # allow the profile AND the model in every Region the profile can route to.
  base_model = trimprefix(var.model_id, "ca.")
  model_arns = [
    "arn:aws:bedrock:${var.region}:${local.account_id}:inference-profile/${var.model_id}",
    "arn:aws:bedrock:ca-central-1::foundation-model/${local.base_model}",
    "arn:aws:bedrock:ca-west-1::foundation-model/${local.base_model}",
  ]
}

# ------------------------------------------------------- bedrock endpoint ----
resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = local.net.vpc_id
  service_name        = "com.amazonaws.${var.region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [local.net.endpoint_subnet_id]
  security_group_ids  = [local.net.endpoints_sg_id]
  private_dns_enabled = true
  tags                = { Name = "${var.prefix}-bedrock-runtime" }
}

# ------------------------------------------------------------ prober role ----
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "prober" {
  name               = "${var.prefix}-prober"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "prober_vpc" {
  role       = aws_iam_role.prober.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "prober_bedrock" {
  statement {
    sid = "InvokeOneModelOnlyThroughTheEndpoint"
    # Converse and ConverseStream are authorized as InvokeModel and InvokeModelWithResponseStream.
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = local.model_arns
    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [aws_vpc_endpoint.bedrock_runtime.id]
    }
  }
}

resource "aws_iam_role_policy" "prober_bedrock" {
  role   = aws_iam_role.prober.id
  policy = data.aws_iam_policy_document.prober_bedrock.json
}

# --------------------------------------------------------- prober Lambdas ----
data "archive_file" "prober" {
  type        = "zip"
  source_file = "${path.module}/../lambda/prober/handler.py"
  output_path = "${path.module}/build/prober.zip"
}

resource "aws_lambda_function" "prober" {
  function_name    = "${var.prefix}-prober"
  role             = aws_iam_role.prober.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.prober.output_path
  source_code_hash = data.archive_file.prober.output_base64sha256
  timeout          = 120
  memory_size      = 256

  vpc_config {
    subnet_ids         = local.net.private_subnet_ids
    security_group_ids = [local.net.workloads_sg_id]
  }
}

resource "aws_lambda_function" "prober_outside" {
  function_name    = "${var.prefix}-prober-outside"
  role             = aws_iam_role.prober.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.prober.output_path
  source_code_hash = data.archive_file.prober.output_base64sha256
  timeout          = 60
  memory_size      = 256
  # No vpc_config: this copy runs on the AWS-managed network, not in your VPC.
}

resource "aws_cloudwatch_log_group" "prober" {
  for_each          = toset([aws_lambda_function.prober.function_name, aws_lambda_function.prober_outside.function_name])
  name              = "/aws/lambda/${each.value}"
  retention_in_days = 7
}

output "bedrock_endpoint_id" { value = aws_vpc_endpoint.bedrock_runtime.id }
output "prober_name" { value = aws_lambda_function.prober.function_name }
output "prober_role_name" { value = aws_iam_role.prober.name }
output "model_id" { value = var.model_id }
output "model_arns" { value = local.model_arns }
