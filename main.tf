provider "aws" {
  region = "us-east-1"
}

# KMS Key for Encryption
resource "aws_kms_key" "email_service_key" {
  description             = "KMS key for email verification service"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "email_service_key_alias" {
  name          = "alias/email-service-key"
  target_key_id = aws_kms_key.email_service_key.key_id
}

# VPC
resource "aws_vpc" "email_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "email-verification-vpc"
  }
}

# Public Subnet (for NAT Gateway)
resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.email_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name = "public-subnet"
  }
}

# Private Subnet (for Lambda)
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.email_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name = "private-subnet"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.email_vpc.id
  tags = {
    Name = "email-igw"
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

# NAT Gateway in Public Subnet
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id
  tags = {
    Name = "email-nat-gateway"
  }
}

# Route Table for Public Subnet
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.email_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route_table_association" "public_rt_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# Route Table for Private Subnet
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.email_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = {
    Name = "private-route-table"
  }
}

resource "aws_route_table_association" "private_rt_assoc" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}

# Security Group for Lambda
resource "aws_security_group" "lambda_sg" {
  name        = "email-lambda-sg"
  description = "Security group for email verification Lambda"
  vpc_id      = aws_vpc.email_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "email-lambda-sg"
  }
}

# SQS Queue for Input (Trigger)
resource "aws_sqs_queue" "email_verification_queue" {
  name                        = "email-verification-queue"
  delay_seconds               = 0
  visibility_timeout_seconds  = 300
  message_retention_seconds   = 86400
  kms_master_key_id           = aws_kms_key.email_service_key.arn
  kms_data_key_reuse_period_seconds = 300
}

# DynamoDB Table with Encryption and Optimizations
resource "aws_dynamodb_table" "email_results" {
  name           = "email_verification_results"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "email"

  attribute {
    name = "email"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.email_service_key.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "email_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# IAM Policy for Lambda (SQS, DynamoDB, CloudWatch Logs, KMS, VPC)
resource "aws_iam_policy" "lambda_policy" {
  name        = "email_lambda_policy"
  description = "Policy for Lambda to access SQS, DynamoDB, CloudWatch Logs, KMS, and VPC"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.email_verification_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.email_results.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:us-east-1:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_key.email_service_key.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach Policy to Role
resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# Lambda Function with VPC Config
resource "aws_lambda_function" "email_verifier" {
  function_name    = "emailVerifier"
  role             = aws_iam_role.lambda_role.arn
  handler          = "main.lambda_handler"
  runtime          = "python3.9"
  filename         = "lambda_function.zip"
  timeout          = 30
  memory_size      = 256

  vpc_config {
    subnet_ids         = [aws_subnet.private_subnet.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      SQS_URL       = aws_sqs_queue.email_verification_queue.url
      DDB_TABLE     = aws_dynamodb_table.email_results.name
      OUTPUT_TARGET = "dynamodb"
    }
  }
}

# Lambda Event Source Mapping (SQS Trigger)
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.email_verification_queue.arn
  function_name    = aws_lambda_function.email_verifier.arn
  enabled          = true
  batch_size       = 10
}

# Outputs
output "sqs_queue_url" {
  description = "The URL of the input SQS queue"
  value       = aws_sqs_queue.email_verification_queue.url
  sensitive   = true
}

output "dynamodb_table_name" {
  description = "The name of the DynamoDB table"
  value       = aws_dynamodb_table.email_results.name
}

output "lambda_function_arn" {
  description = "The ARN of the Lambda function"
  value       = aws_lambda_function.email_verifier.arn
}

output "kms_key_arn" {
  description = "The ARN of the KMS key"
  value       = aws_kms_key.email_service_key.arn
}

output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.email_vpc.id
}

output "private_subnet_id" {
  description = "The ID of the private subnet"
  value       = aws_subnet.private_subnet.id
}
