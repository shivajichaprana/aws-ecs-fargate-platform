output "service_name" {
  description = "Name of the ECS service."
  value       = local.ecs_service_name
}

output "service_id" {
  description = "ARN/ID of the ECS service."
  value       = local.ecs_service_id
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

output "target_group_name" {
  description = "Name of the target group serving production traffic."
  value       = aws_lb_target_group.this.name
}

output "green_target_group_arn" {
  description = "ARN of the replacement target group used by traffic-shifting rollouts, or null for in-place rollouts."
  value       = one(aws_lb_target_group.green[*].arn)
}

output "green_target_group_arn_suffix" {
  description = "ARN suffix of the replacement target group, used as a CloudWatch alarm dimension during a rollout."
  value       = one(aws_lb_target_group.green[*].arn_suffix)
}

output "green_target_group_name" {
  description = "Name of the replacement target group, or null for in-place rollouts."
  value       = one(aws_lb_target_group.green[*].name)
}

output "container_name" {
  description = "Container name the load balancer routes to, required to render a deployment AppSpec."
  value       = local.container_name
}

output "deployment_controller_type" {
  description = "Rollout mode the service was created with."
  value       = var.deployment_controller_type
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

output "service_connect_enabled" {
  description = "Whether the service is registered into a Service Connect namespace."
  value       = local.enable_service_connect
}

output "service_connect_endpoint" {
  description = "Service Connect client endpoint (alias:port) peers use to reach the service, or null when Service Connect is disabled."
  value       = local.enable_service_connect ? "${local.service_connect_alias}:${local.service_connect_dns_port}" : null
}
