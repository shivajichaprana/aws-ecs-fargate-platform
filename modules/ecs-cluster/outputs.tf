output "cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.this.arn
}

output "cluster_id" {
  description = "ID of the ECS cluster."
  value       = aws_ecs_cluster.this.id
}

output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.this.name
}

output "capacity_providers" {
  description = "Capacity providers associated with the cluster."
  value       = aws_ecs_cluster_capacity_providers.this.capacity_providers
}

output "exec_log_group_name" {
  description = "Name of the ECS Exec audit log group, if enabled."
  value       = var.enable_execute_command_logging ? aws_cloudwatch_log_group.exec[0].name : null
}

output "exec_kms_key_arn" {
  description = "KMS key ARN used for ECS Exec session encryption, if enabled."
  value       = local.exec_kms_key_arn
}
