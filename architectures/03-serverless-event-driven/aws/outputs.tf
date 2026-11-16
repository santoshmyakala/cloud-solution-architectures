output "api_endpoint" {
  value = "${aws_apigatewayv2_api.this.api_endpoint}/orders"
}

output "dead_letter_queue_url" {
  value = aws_sqs_queue.dlq.url
}
