output "namespace_arn" {
  description = "ARN of the Service Connect namespace. Pass this to the cluster and service modules to enable Service Connect."
  value       = aws_service_discovery_http_namespace.this.arn
}

output "namespace_id" {
  description = "ID of the Service Connect namespace."
  value       = aws_service_discovery_http_namespace.this.id
}

output "namespace_name" {
  description = "Name of the Service Connect namespace."
  value       = aws_service_discovery_http_namespace.this.name
}
