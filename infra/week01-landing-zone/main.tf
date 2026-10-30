# =============================================================================
# Week 1: a private VPC for AI workloads
# -----------------------------------------------------------------------------
#   VPC 10.20.0.0/22 with NO internet gateway and NO NAT gateway.
#   Nothing in it can reach the internet. Everything it needs from AWS
#   (Bedrock, ECR, logs, secrets) comes through VPC endpoints, added in the
#   week that needs them, so you only pay for what you use.
#
#     private-a 10.20.0.0/25    (AZ a)  workloads + interface endpoints
#     private-b 10.20.0.128/25  (AZ b)  workloads (the load balancer needs 2 AZs)
#
#   S3 gateway endpoint (free): container image layers come from S3.
#   VPC flow logs to CloudWatch Logs: evidence of "nothing leaves".
#   A security group for interface endpoints: HTTPS from inside the VPC only.
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.20.0.0/22"
  enable_dns_support   = true # required for private DNS on interface endpoints
  enable_dns_hostnames = true
  tags                 = { Name = "${var.prefix}-vpc" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.lab.id
  cidr_block        = cidrsubnet(aws_vpc.lab.cidr_block, 3, count.index) # /25s
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.prefix}-private-${substr(local.azs[count.index], -1, 1)}" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.prefix}-private" }
  # No 0.0.0.0/0 route on purpose.
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.lab.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${var.prefix}-s3-gateway" }
}

resource "aws_security_group" "endpoints" {
  name        = "${var.prefix}-vpc-endpoints"
  description = "HTTPS to interface endpoints from inside the VPC only"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "HTTPS from the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.lab.cidr_block]
  }
}

resource "aws_security_group" "workloads" {
  name        = "${var.prefix}-workloads"
  description = "Lambda and ECS tasks. Outbound stays inside the VPC (there is no internet route anyway)."
  vpc_id      = aws_vpc.lab.id
  # Rules are separate resources so later weeks can add their own
  # (for example week 4 lets the load balancer in) without fighting this file.
}

resource "aws_vpc_security_group_ingress_rule" "workloads_self" {
  security_group_id            = aws_security_group.workloads.id
  referenced_security_group_id = aws_security_group.workloads.id
  ip_protocol                  = "-1"
  description                  = "From other workloads"
}

resource "aws_vpc_security_group_egress_rule" "workloads_vpc" {
  security_group_id = aws_security_group.workloads.id
  cidr_ipv4         = aws_vpc.lab.cidr_block
  ip_protocol       = "-1"
  description       = "Inside the VPC (endpoints, load balancer, database)"
}

resource "aws_vpc_security_group_egress_rule" "workloads_s3" {
  security_group_id = aws_security_group.workloads.id
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "S3 gateway endpoint (container image layers)"
}

# ------------------------------------------------------------ flow logs ------
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/${var.prefix}/vpc-flow-logs"
  retention_in_days = 7
}

data "aws_iam_policy_document" "flow_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow" {
  name               = "${var.prefix}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_assume.json
}

data "aws_iam_policy_document" "flow_write" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.flow.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow" {
  role   = aws_iam_role.flow.id
  policy = data.aws_iam_policy_document.flow_write.json
}

resource "aws_flow_log" "vpc" {
  vpc_id          = aws_vpc.lab.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow.arn
  iam_role_arn    = aws_iam_role.flow.arn
}

# --------------------------------------------------------------- outputs -----
output "vpc_id" { value = aws_vpc.lab.id }
output "vpc_cidr" { value = aws_vpc.lab.cidr_block }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "endpoint_subnet_id" { value = aws_subnet.private[0].id }
output "endpoints_sg_id" { value = aws_security_group.endpoints.id }
output "workloads_sg_id" { value = aws_security_group.workloads.id }
