terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name, used for naming resources and S3 key prefix"
  type        = string
}

variable "tf_state_bucket" {
  description = "S3 bucket used for Terraform state and Lambda artifact"
  type        = string
}

locals {
  lambda_s3_key    = "${var.project_name}/lambda.zip"
  function_name    = "${var.project_name}-function"
  role_name        = "${var.project_name}-lambda-role"
}

# IAM role for Lambda execution
resource "aws_iam_role" "lambda_exec" {
  name = local.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda function — artifact pulled from S3
resource "aws_lambda_function" "app" {
  function_name = local.function_name
  role          = aws_iam_role.lambda_exec.arn

  handler  = "lambda_handler.handler"
  runtime  = "python3.11"

  s3_bucket = var.tf_state_bucket
  s3_key    = local.lambda_s3_key

  timeout     = 30
  memory_size = 256

  environment {
    variables = {
      APP_ENV = "production"
    }
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic]
}

# Function URL — anonymous public access
resource "aws_lambda_function_url" "app" {
  function_name      = aws_lambda_function.app.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["*"]
    allow_methods = ["*"]
    allow_headers = ["*"]
  }
}

# Permission that allows the Function URL to invoke the Lambda anonymously.
# depends_on ensures the URL resource is fully created before the permission
# is registered — without this AWS may silently drop the permission, causing 403.
resource "aws_lambda_permission" "function_url_public" {
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.app.function_name
  principal              = "*"
  function_url_auth_type = "NONE"

  depends_on = [aws_lambda_function_url.app]

  lifecycle {
    replace_triggered_by = [aws_lambda_function_url.app]
  }
}

output "function_url" {
  description = "Public HTTPS endpoint of the Lambda Function URL"
  value       = aws_lambda_function_url.app.function_url
}

output "function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.app.function_name
}