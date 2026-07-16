output "service_name" {
  description = "Name of the ECS service."
  value       = aws_ecs_service.this.name
}

output "service_id" {
  description = "ARN/ID of the ECS service."
  value       = aws_ecs_service.this.id
}

output "task_definition_arn" {
  description = "ARN of the active task definition revision."
  value       = aws_ecs_task_definition.this.arn
}

output "task_definition_family" {
  description = "Family name of the task definition."
  value       = aws_ecs_task_definition.this.family
}

output "target_group_arn" {
  description = "ARN of the ALB target group fronting the service."
  value       = aws_lb_target_group.this.arn
}

output "target_group_arn_suffix" {
  description = "ARN suffix of the target group, useful for CloudWatch metrics and request-count scaling."
  value       = aws_lb_target_group.this.arn_suffix
}

output "security_group_id" {
  description = "ID of the module-managed task security group."
  value       = aws_security_group.task.id
}

output "task_role_arn" {
  description = "ARN of the task role assumed by the application."
  value       = local.task_role_arn
}

output "execution_role_arn" {
  description = "ARN of the task execution role used by the ECS agent."
  value       = local.execution_role_arn
}

output "log_group_name" {
  description = "Name of the container log group."
  value       = aws_cloudwatch_log_group.this.name
}

output "autoscaling_target_resource_id" {
  description = "Application Auto Scaling resource id for the service."
  value       = aws_appautoscaling_target.this.resource_id
}

output "listener_rule_arn" {
  description = "ARN of the ALB listener rule, when one is created."
  value       = local.create_listener_rule ? aws_lb_listener_rule.this[0].arn : null
}
