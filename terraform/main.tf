terraform {
  required_providers {
    aws     = { source = "hashicorp/aws" }
    random  = { source = "hashicorp/random" }
    archive = { source = "hashicorp/archive" }
  }
}

variable "region" { default = "ap-south-1" }
variable "name" { default = "agentbox-tf" }
variable "image_uri" { description = "ECR image of the sandbox runner" }

provider "aws" { region = var.region }

data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_cloudwatch_log_group" "logs" {
  name              = "/ecs/${var.name}"
  retention_in_days = 1
}

resource "aws_ecs_cluster" "c" { name = var.name }

data "aws_iam_policy_document" "ecs_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Zero permissions on purpose: no policy attached.
resource "aws_iam_role" "task" {
  name               = "${var.name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json
}

resource "aws_security_group" "sandbox" {
  name        = "${var.name}-sg"
  description = "Agentbox sandbox"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_task_definition" "sandbox" {
  family                   = "${var.name}-sandbox"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  volume { name = "scratch" }

  container_definitions = jsonencode([{
    name                   = "runner"
    image                  = var.image_uri
    essential              = true
    user                   = "1000"
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = 8080, protocol = "tcp" }]
    environment            = [{ name = "RUNNER_TOKEN", value = "set-per-session" }]
    mountPoints            = [{ sourceVolume = "scratch", containerPath = "/tmp" }]
    linuxParameters        = { capabilities = { drop = ["ALL"] } }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.logs.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "runner"
      }
    }
  }])
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_access" {
  name = "${var.name}-lambda-access"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecs:RunTask", "ecs:StopTask", "ecs:DescribeTasks", "ecs:ListTasks"], Resource = "*" },
      { Effect = "Allow", Action = "ec2:DescribeNetworkInterfaces", Resource = "*" },
      { Effect = "Allow", Action = "iam:PassRole", Resource = [aws_iam_role.execution.arn, aws_iam_role.task.arn] }
    ]
  })
}

resource "random_password" "api_key" {
  length  = 32
  special = false
}

data "archive_file" "orchestrator" {
  type        = "zip"
  source_file = "${path.module}/../lambda/lambda_function.py"
  output_path = "${path.module}/orchestrator.zip"
}

data "archive_file" "janitor" {
  type        = "zip"
  source_file = "${path.module}/../lambda/janitor.py"
  output_path = "${path.module}/janitor.zip"
}

resource "aws_lambda_function" "orchestrator" {
  function_name    = "${var.name}-orchestrator"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "lambda_function.handler"
  filename         = data.archive_file.orchestrator.output_path
  source_code_hash = data.archive_file.orchestrator.output_base64sha256
  timeout          = 120
  memory_size      = 256
  environment {
    variables = {
      CLUSTER   = aws_ecs_cluster.c.name
      TASK_DEF  = aws_ecs_task_definition.sandbox.family
      SUBNET_ID = sort(data.aws_subnets.default.ids)[0]
      SG_ID     = aws_security_group.sandbox.id
      API_KEY   = random_password.api_key.result
    }
  }
}

resource "aws_lambda_function_url" "orchestrator" {
  function_name      = aws_lambda_function.orchestrator.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "url_public" {
  statement_id           = "url-public"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.orchestrator.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "url_invoke" {
  statement_id             = "url-public-invoke"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.orchestrator.function_name
  principal                = "*"
  invoked_via_function_url = true
}

resource "aws_lambda_function" "janitor" {
  function_name    = "${var.name}-janitor"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "janitor.handler"
  filename         = data.archive_file.janitor.output_path
  source_code_hash = data.archive_file.janitor.output_base64sha256
  timeout          = 30
  environment {
    variables = { CLUSTER = aws_ecs_cluster.c.name }
  }
}

resource "aws_cloudwatch_event_rule" "janitor" {
  name                = "${var.name}-janitor-rule"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "janitor" {
  rule = aws_cloudwatch_event_rule.janitor.name
  arn  = aws_lambda_function.janitor.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "events-invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.janitor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.janitor.arn
}

output "url" { value = aws_lambda_function_url.orchestrator.function_url }
output "api_key" {
  value     = random_password.api_key.result
  sensitive = true
}
