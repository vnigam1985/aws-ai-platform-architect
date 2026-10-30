# =============================================================================
# Week 4: the AI gateway
# -----------------------------------------------------------------------------
# AWS has no managed "token budget per team" gateway for Bedrock. AWS's own
# answer is the "Guidance for Multi-Provider Generative AI Gateway on AWS":
# LiteLLM on ECS with a database. This week builds a small version of it:
#
#   - VPC endpoints the gateway needs: ECR (api + dkr), CloudWatch Logs,
#     Secrets Manager (one AZ, for cost)
#   - ECR repositories for the gateway image and the bank app image (week 5)
#   - Aurora PostgreSQL Serverless v2 that scales to zero when idle (team keys)
#   - Secrets Manager: the gateway admin key and the database URL
#   - ECS Fargate service running LiteLLM, with a task role that:
#       * may call Bedrock (and apply the bank guardrail)
#       * carries the week 3 permissions boundary
#   - An INTERNAL Application Load Balancer, port 4000. Nothing outside the VPC
#     can reach it.
# =============================================================================

data "terraform_remote_state" "w1" {
  backend = "local"
  config  = { path = "${path.module}/../week01-landing-zone/terraform.tfstate" }
}
data "terraform_remote_state" "w2" {
  backend = "local"
  config  = { path = "${path.module}/../week02-private-model/terraform.tfstate" }
}
data "terraform_remote_state" "w3" {
  backend = "local"
  config  = { path = "${path.module}/../week03-guardrails/terraform.tfstate" }
}

data "aws_caller_identity" "me" {}

locals {
  net        = data.terraform_remote_state.w1.outputs
  model_id   = data.terraform_remote_state.w2.outputs.model_id
  model_arns = data.terraform_remote_state.w2.outputs.model_arns
  guard      = data.terraform_remote_state.w3.outputs
  account_id = data.aws_caller_identity.me.account_id
}

variable "gateway_image_tag" {
  description = "Tag of the gateway image in ECR. make week4-images pushes v1."
  type        = string
  default     = "v1"
}

variable "bank_model_override" {
  description = "Week 7 sets this to bedrock/converse/<application inference profile ARN> so token costs carry team tags."
  type        = string
  default     = ""
}

variable "gateway_desired_count" {
  description = "Set to 0 to stop paying for the gateway task between sessions."
  type        = number
  default     = 1
}

# ------------------------------------------------------- VPC endpoints -------
resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(["ecr.api", "ecr.dkr", "logs", "secretsmanager"])
  vpc_id              = local.net.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [local.net.endpoint_subnet_id]
  security_group_ids  = [local.net.endpoints_sg_id]
  private_dns_enabled = true
  tags                = { Name = "${var.prefix}-${each.key}" }
}

# ---------------------------------------------------------------- ECR --------
resource "aws_ecr_repository" "repo" {
  for_each             = toset(["ai-gateway", "maple-bank-assistant"])
  name                 = "${var.prefix}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # lab only: lets `make destroy` remove images too
  image_scanning_configuration {
    scan_on_push = true
  }
}

# ------------------------------------------------------------ secrets --------
resource "random_password" "master_key" {
  length  = 40
  special = false
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "master_key" {
  name                    = "${var.prefix}/gateway/master-key"
  description             = "LiteLLM admin key. Only the platform team uses it, to create team keys."
  recovery_window_in_days = 0 # lab only: delete immediately on destroy
}

resource "aws_secretsmanager_secret_version" "master_key" {
  secret_id     = aws_secretsmanager_secret.master_key.id
  secret_string = "sk-${random_password.master_key.result}"
}

resource "aws_secretsmanager_secret" "db_url" {
  name                    = "${var.prefix}/gateway/database-url"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_url" {
  secret_id     = aws_secretsmanager_secret.db_url.id
  secret_string = "postgresql://litellm:${random_password.db.result}@${aws_rds_cluster.keys.endpoint}:5432/litellm"
}

# ----------------------------------------- Aurora Serverless v2 (keys DB) ----
resource "aws_db_subnet_group" "keys" {
  name       = "${var.prefix}-gateway-db"
  subnet_ids = local.net.private_subnet_ids
}

resource "aws_security_group" "db" {
  name        = "${var.prefix}-gateway-db"
  description = "Postgres from workloads only"
  vpc_id      = local.net.vpc_id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [local.net.workloads_sg_id]
  }
}

resource "aws_rds_cluster" "keys" {
  cluster_identifier     = "${var.prefix}-gateway-keys"
  engine                 = "aurora-postgresql"
  engine_mode            = "provisioned"
  engine_version         = "16.6"
  database_name          = "litellm"
  master_username        = "litellm"
  master_password        = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.keys.name
  vpc_security_group_ids = [aws_security_group.db.id]
  storage_encrypted      = true
  skip_final_snapshot    = true # lab only
  deletion_protection    = false

  serverlessv2_scaling_configuration {
    min_capacity             = 0 # scale to zero: no compute cost while idle
    max_capacity             = 1
    seconds_until_auto_pause = 600
  }
}

resource "aws_rds_cluster_instance" "keys" {
  identifier         = "${var.prefix}-gateway-keys-1"
  cluster_identifier = aws_rds_cluster.keys.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.keys.engine
  engine_version     = aws_rds_cluster.keys.engine_version
}

# ------------------------------------------------------------- IAM -----------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: what ECS itself needs to start the task.
resource "aws_iam_role" "execution" {
  name               = "${var.prefix}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:${var.prefix}/*"
    }]
  })
}

# Task role: what the gateway code may do. Bounded by the week 3 boundary.
resource "aws_iam_role" "gateway" {
  name                 = "${var.prefix}-ai-gateway"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  permissions_boundary = local.guard.boundary_arn
}

resource "aws_iam_role_policy" "gateway_bedrock" {
  role = aws_iam_role.gateway.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CallTheApprovedModel"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = concat(local.model_arns, [
          # Week 7: tagged application inference profiles for cost allocation
          "arn:aws:bedrock:${var.region}:${local.account_id}:application-inference-profile/*",
        ])
      },
      {
        Sid      = "ApplyTheBankGuardrail"
        Effect   = "Allow"
        Action   = ["bedrock:ApplyGuardrail"]
        Resource = [local.guard.guardrail_arn]
      },
    ]
  })
}

# ----------------------------------------------- load balancer (internal) ----
resource "aws_security_group" "alb" {
  name        = "${var.prefix}-internal-alb"
  description = "Internal ALB: gateway 4000 and app 80, from inside the VPC only"
  vpc_id      = local.net.vpc_id
  ingress {
    from_port   = 4000
    to_port     = 4000
    protocol    = "tcp"
    cidr_blocks = [local.net.vpc_cidr]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [local.net.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.net.vpc_cidr]
  }
}

# Let the load balancer reach the gateway (4000) and app (8000) tasks.
resource "aws_vpc_security_group_ingress_rule" "alb_to_tasks" {
  for_each                     = toset(["4000", "8000"])
  security_group_id            = local.net.workloads_sg_id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
  ip_protocol                  = "tcp"
  description                  = "From the internal ALB"
}

resource "aws_lb" "internal" {
  name               = "${var.prefix}-internal"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.net.private_subnet_ids
}

resource "aws_lb_target_group" "gateway" {
  name        = "${var.prefix}-gateway"
  port        = 4000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = local.net.vpc_id
  health_check {
    path    = "/health/liveliness"
    matcher = "200"
  }
}

resource "aws_lb_listener" "gateway" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 4000
  protocol          = "HTTP" # inside the VPC only. Production: HTTPS with an internal certificate.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}

# ------------------------------------------------------------ ECS ------------
resource "aws_ecs_cluster" "lab" {
  name = "${var.prefix}-cluster"
  setting {
    name  = "containerInsights"
    value = "disabled" # turn on in week 7 if you want per-task metrics (extra cost)
  }
}

resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/${var.prefix}/ai-gateway"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "gateway" {
  family                   = "${var.prefix}-ai-gateway"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.gateway.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name         = "litellm"
    image        = "${aws_ecr_repository.repo["ai-gateway"].repository_url}:${var.gateway_image_tag}"
    essential    = true
    portMappings = [{ containerPort = 4000, protocol = "tcp" }]
    environment = [
      { name = "BANK_MODEL", value = var.bank_model_override != "" ? var.bank_model_override : "bedrock/converse/${local.model_id}" },
      { name = "AWS_REGION", value = var.region },
      { name = "GUARDRAIL_ARN", value = local.guard.guardrail_arn },
      { name = "GUARDRAIL_VERSION", value = tostring(local.guard.guardrail_version) },
      { name = "LITELLM_LOCAL_MODEL_COST_MAP", value = "True" },
    ]
    secrets = [
      { name = "LITELLM_MASTER_KEY", valueFrom = aws_secretsmanager_secret.master_key.arn },
      { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.db_url.arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.gateway.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "gateway"
      }
    }
  }])
}

resource "aws_ecs_service" "gateway" {
  name            = "ai-gateway"
  cluster         = aws_ecs_cluster.lab.id
  task_definition = aws_ecs_task_definition.gateway.arn
  desired_count   = var.gateway_desired_count
  launch_type     = "FARGATE"
  # LiteLLM runs database migrations on first start; give it time.
  health_check_grace_period_seconds = 300

  network_configuration {
    subnets          = local.net.private_subnet_ids
    security_groups  = [local.net.workloads_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.gateway.arn
    container_name   = "litellm"
    container_port   = 4000
  }

  depends_on = [aws_lb_listener.gateway, aws_rds_cluster_instance.keys, aws_vpc_endpoint.interface]
}

output "gateway_url" { value = "http://${aws_lb.internal.dns_name}:4000" }
output "alb_dns" { value = aws_lb.internal.dns_name }
output "alb_arn" { value = aws_lb.internal.arn }
output "alb_sg_id" { value = aws_security_group.alb.id }
output "ecs_cluster" { value = aws_ecs_cluster.lab.name }
output "execution_role_arn" { value = aws_iam_role.execution.arn }
output "ecr_gateway" { value = aws_ecr_repository.repo["ai-gateway"].repository_url }
output "ecr_app" { value = aws_ecr_repository.repo["maple-bank-assistant"].repository_url }
output "master_key_secret" { value = aws_secretsmanager_secret.master_key.name }
output "gateway_log_group" { value = aws_cloudwatch_log_group.gateway.name }
