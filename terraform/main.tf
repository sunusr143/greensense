terraform {
  required_version = ">= 1.6"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.60" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# ---- Device identity: one thing + one certificate per board ----
resource "aws_iot_thing" "device" {
  for_each = var.device_ids
  name     = each.key
}

resource "aws_iot_certificate" "device" {
  for_each = var.device_ids
  active   = true
}

resource "aws_iot_thing_principal_attachment" "device" {
  for_each  = var.device_ids
  thing     = aws_iot_thing.device[each.key].name
  principal = aws_iot_certificate.device[each.key].arn
}

# Least privilege: a device may connect only as itself and publish only to its own topic.
resource "aws_iot_policy" "device" {
  name = "greensense-device"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "iot:Connect"
        Resource = "arn:aws:iot:${var.region}:${data.aws_caller_identity.current.account_id}:client/$${iot:Connection.Thing.ThingName}"
      },
      {
        Effect   = "Allow"
        Action   = "iot:Publish"
        Resource = "arn:aws:iot:${var.region}:${data.aws_caller_identity.current.account_id}:topic/greensense/$${iot:Connection.Thing.ThingName}/telemetry"
      },
    ]
  })
}

resource "aws_iot_policy_attachment" "device" {
  for_each = var.device_ids
  policy   = aws_iot_policy.device.name
  target   = aws_iot_certificate.device[each.key].arn
}

# ---- Storage ----
resource "aws_dynamodb_table" "readings" {
  name         = "greensense-readings"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "device_id"
  range_key    = "ts"

  attribute {
    name = "device_id"
    type = "S"
  }
  attribute {
    name = "ts"
    type = "N"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = false # enable and add expires_at in the Lambda to cap retention
  }

  point_in_time_recovery { enabled = true }
}

# ---- Ingest Lambda ----
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../lambda/handler.py"
  output_path = "${path.module}/build/handler.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "greensense-ingest"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "lambda" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = aws_dynamodb_table.readings.arn },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.lambda.arn}:*" },
    ]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/greensense-ingest"
  retention_in_days = 30
}

resource "aws_lambda_function" "ingest" {
  function_name    = "greensense-ingest"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 10
  environment {
    variables = { TABLE_NAME = aws_dynamodb_table.readings.name }
  }
  depends_on = [aws_cloudwatch_log_group.lambda]
}

# ---- IoT rule routes every device's telemetry to the Lambda ----
resource "aws_iot_topic_rule" "telemetry" {
  name    = "greensense_telemetry"
  enabled = true
  # topic(2) is the device segment of greensense/<device>/telemetry; it overrides any
  # device_id in the payload so a device cannot impersonate another.
  sql         = "SELECT *, topic(2) AS device_id FROM 'greensense/+/telemetry'"
  sql_version = "2016-03-23"

  lambda { function_arn = aws_lambda_function.ingest.arn }
}

resource "aws_lambda_permission" "iot" {
  statement_id  = "AllowIoTRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "iot.amazonaws.com"
  source_arn    = aws_iot_topic_rule.telemetry.arn
}

# ---- Monitoring: alarm when a device goes silent ----
resource "aws_sns_topic" "alerts" {
  name = "greensense-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "silent" {
  for_each            = var.device_ids
  alarm_name          = "greensense-${each.key}-silent"
  alarm_description   = "No readings received from ${each.key} recently"
  namespace           = "GreenSense"
  metric_name         = "ReadingsReceived"
  dimensions          = { DeviceId = each.key }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = ceil(var.silence_minutes / 5)
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # no data at all means the device is silent
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "bad_data" {
  for_each            = var.device_ids
  alarm_name          = "greensense-${each.key}-invalid-readings"
  alarm_description   = "Device is sending readings that fail validation"
  namespace           = "GreenSense"
  metric_name         = "InvalidReadings"
  dimensions          = { DeviceId = each.key }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
