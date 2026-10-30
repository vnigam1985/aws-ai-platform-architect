# =============================================================================
# Week 5: run the bank assistant privately
# -----------------------------------------------------------------------------
#   - The Maple Leaf Bank app on ECS Fargate, in the private subnets
#   - Reachable only through the internal load balancer, port 80
#   - It calls the model ONLY through the gateway, with its own TEAM key
#     (created by make week5-key, stored in Secrets Manager, injected by ECS)
#   - Its task role has NO Bedrock permissions at all. Even if the app were
#     compromised, it couldn't call Bedrock directly.
# =============================================================================

data "terraform_remote_state" "w1" {
  backend = "local"
  config  = { path = "${path.module}/../week01-landing-zone/terraform.tfstate" }
}
data "terraform_remote_state" "w4" {
  backend = "local"
  config  = { path = "${path.module}/../week04-ai-gateway/terraform.tfstate" }
}

locals {
  net = data.terraform_remote_state.w1.outputs
  gw  = data.terraform_remote_state.w4.outputs
}

variable "app_image_tag" {
  type    = string
  default = "v1"
}

variable "app_desired_count" {
  type    = number
  default = 1
}

# The team key is created on the gateway by make week5-key, which then writes it here.
resource "aws_secretsmanager_secret" "team_key" {
  name                    = "${var.prefix}/apps/retail-banking/gateway-key"
  description             = "The bank app's team key for the AI gateway (not a model key)"
  recovery_window_in_days = 0
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.prefix}-bank-app"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  # No policies attached on purpose: the app needs no AWS permissions.
}

resource "aws_lb_target_group" "app" {
  name        = "${var.prefix}-bank-app"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = local.net.vpc_id
  health_check {
    path    = "/health"
    matcher = "200"
  }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = local.gw.alb_arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.prefix}/bank-app"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.prefix}-bank-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = local.gw.execution_role_arn
  task_role_arn            = aws_iam_role.app.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name         = "bank-assistant"
    image        = "${local.gw.ecr_app}:${var.app_image_tag}"
    essential    = true
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]
    environment = [
      { name = "LLM_MODE", value = "llm" },
      { name = "OPENAI_BASE_URL", value = "${local.gw.gateway_url}/v1" },
      { name = "MODEL", value = "bank-chat" },
    ]
    secrets = [
      { name = "OPENAI_API_KEY", valueFrom = aws_secretsmanager_secret.team_key.arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = "bank-assistant"
  cluster         = local.gw.ecs_cluster
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.app_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.net.private_subnet_ids
    security_groups  = [local.net.workloads_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "bank-assistant"
    container_port   = 8000
  }

  depends_on = [aws_lb_listener.app]
}

output "app_url" { value = "http://${local.gw.alb_dns}" }
output "team_key_secret" { value = aws_secretsmanager_secret.team_key.name }
