output "application_name" {
  description = "Name of the CodeDeploy application."
  value       = aws_codedeploy_app.this.name
}

output "deployment_group_name" {
  description = "Name of the ECS blue/green deployment group."
  value       = aws_codedeploy_deployment_group.this.deployment_group_name
}

output "deployment_config_name" {
  description = "Traffic-shifting configuration applied to deployments."
  value       = aws_codedeploy_deployment_group.this.deployment_config_name
}

output "service_role_arn" {
  description = "ARN of the service role CodeDeploy assumes."
  value       = local.codedeploy_role
}

output "production_listener_arns" {
  description = "Listener ARNs whose default action is swapped during a deployment."
  value       = local.production_listener_arns
}

output "test_listener_arns" {
  description = "Listener ARNs serving the replacement task set before traffic shifts, or an empty list when no test route is configured."
  value       = local.test_listener_arns
}

output "rollback_alarm_names" {
  description = "CloudWatch alarms that stop and roll back an in-flight deployment."
  value       = local.alarm_names
}

output "appspec_yaml" {
  description = "Rendered AppSpec for the deployment pipeline. The task definition placeholder is substituted with the revision being rolled out."
  value = templatefile("${path.module}/templates/appspec.yaml.tftpl", {
    task_definition_placeholder = "<TASK_DEFINITION>"
    container_name              = var.container_name
    container_port              = var.container_port
    platform_version            = "LATEST"
  })
}
