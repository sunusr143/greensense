output "iot_endpoint_hint" {
  description = "Run: aws iot describe-endpoint --endpoint-type iot:Data-ATS"
  value       = "aws iot describe-endpoint --endpoint-type iot:Data-ATS"
}

output "certificate_pem" {
  description = "Device certificates (flash to each board). Private keys are in state: use a remote encrypted backend."
  value       = { for k, c in aws_iot_certificate.device : k => c.certificate_pem }
  sensitive   = true
}

output "private_keys" {
  value     = { for k, c in aws_iot_certificate.device : k => c.private_key }
  sensitive = true
}
