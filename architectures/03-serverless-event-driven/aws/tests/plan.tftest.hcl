mock_provider "aws" {
  override_during = plan
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:eu-north-1:111111111111:orders", url = "https://sqs.eu-north-1.amazonaws.com/111111111111/orders" }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:eu-north-1:111111111111:table/orders" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:eu-north-1:111111111111:log-group:/aws/lambda/orders" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/orders" }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn        = "arn:aws:lambda:eu-north-1:111111111111:function:orders"
      invoke_arn = "arn:aws:apigateway:eu-north-1:lambda:path/2015-03-31/functions/arn:aws:lambda:eu-north-1:111111111111:function:orders/invocations"
    }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = { execution_arn = "arn:aws:execute-api:eu-north-1:111111111111:abc123" }
  }
  override_data {
    target = data.aws_iam_policy_document.lambda_assume
    values = { json = "{}" }
  }
}

run "reliability" {
  command = plan

  assert {
    condition     = jsondecode(aws_sqs_queue.orders.redrive_policy).maxReceiveCount == 5
    error_message = "Messages must move to the DLQ after 5 attempts."
  }
  assert {
    condition     = aws_lambda_event_source_mapping.processor.function_response_types == toset(["ReportBatchItemFailures"])
    error_message = "Partial batch failures must be reported so good records are not retried."
  }
  assert {
    condition     = aws_sqs_queue.orders.visibility_timeout_seconds >= aws_lambda_function.fn["processor"].timeout * 6
    error_message = "Queue visibility timeout must be >= 6x the processor timeout."
  }
  assert {
    condition     = aws_dynamodb_table.orders.point_in_time_recovery[0].enabled
    error_message = "PITR must be on for the orders table."
  }
}

run "least_privilege" {
  command = plan

  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.fn["ingest"].policy).Statement : s.Action if contains(s.Action, "sqs:SendMessage")] == [["sqs:SendMessage"]]
    error_message = "Ingest may only send to the queue."
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.fn["ingest"].policy, "dynamodb")
    error_message = "Ingest must not touch DynamoDB."
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.fn["processor"].policy).Statement : !contains(s.Action, "*")])
    error_message = "No wildcard actions."
  }
  assert {
    condition     = aws_apigatewayv2_route.post_orders.authorization_type != "NONE"
    error_message = "The API must not be anonymous."
  }
}
