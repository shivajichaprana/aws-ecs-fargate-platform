# service module

Runs one containerized service on an existing Fargate cluster. It bundles the
task definition, ECS service, ALB target group, task security group, IAM roles,
and target-tracking autoscaling behind a small input surface, so a new service
is onboarded by supplying an image, a port, and the cluster and network it
belongs to.

## What it creates

- `aws_ecs_task_definition` — a Fargate task with a single container, awslogs
  logging to a dedicated CloudWatch log group, a configurable runtime platform,
  and an optional container health check. Invalid CPU/memory pairs are rejected
  by a precondition before the API sees them.
- `aws_ecs_service` — wired to the target group, with a rolling deployment guarded
  by a circuit breaker and automatic rollback. Autoscaling owns `desired_count`.
- `aws_lb_target_group` (target type `ip`) and an optional `aws_lb_listener_rule`
  with host-header and/or path-pattern conditions.
- `aws_security_group` for the task ENIs, allowing inbound traffic only from the
  ALB security group on the container port.
- Least-privilege IAM roles (execution + task). The task role gains only the SSM
  messaging permissions required for ECS Exec, and only when Exec is enabled.
- `aws_appautoscaling_target` plus target-tracking policies on CPU, and optionally
  memory and ALB request count per target.

## Usage

```hcl
module "checkout" {
  source = "../../modules/service"

  name_prefix  = "ecs-platform"
  service_name = "checkout"
  environment  = "prod"

  cluster_arn  = module.cluster.cluster_arn
  cluster_name = module.cluster.cluster_name

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  container_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/checkout:1.4.2"
  container_port  = 8080
  cpu             = 512
  memory          = 1024

  # Front the service on a shared ALB listener.
  alb_listener_arn       = var.https_listener_arn
  alb_security_group_id  = var.alb_security_group_id
  alb_arn_suffix         = var.alb_arn_suffix
  listener_rule_priority = 100
  listener_host_headers  = ["checkout.example.com"]

  # Scale on CPU and on ALB requests per task.
  min_capacity         = 3
  max_capacity         = 20
  cpu_target_value     = 60
  request_count_target = 1000
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | `string` | — | Platform prefix shared by all services. |
| `service_name` | `string` | — | Short, unique service name. |
| `environment` | `string` | `dev` | Environment identifier. |
| `cluster_arn` | `string` | — | ECS cluster ARN. |
| `cluster_name` | `string` | — | ECS cluster name (for the autoscaling resource id). |
| `vpc_id` | `string` | — | VPC for the target group and task security group. |
| `subnet_ids` | `list(string)` | — | Subnets for task placement (use private subnets). |
| `assign_public_ip` | `bool` | `false` | Assign public IPs to tasks. |
| `container_image` | `string` | — | Container image reference. |
| `container_port` | `number` | `8080` | Container/target-group port. |
| `container_command` | `list(string)` | `[]` | Optional entrypoint override. |
| `container_environment` | `map(string)` | `{}` | Non-sensitive environment variables. |
| `cpu` | `number` | `256` | Fargate task CPU units. |
| `memory` | `number` | `512` | Fargate task memory (MiB). |
| `cpu_architecture` | `string` | `X86_64` | `X86_64` or `ARM64`. |
| `container_health_check` | `object` | `{}` | Optional container health check. |
| `task_execution_role_arn` | `string` | `null` | Bring-your-own execution role; created when null. |
| `task_role_arn` | `string` | `null` | Bring-your-own task role; created when null. |
| `log_retention_in_days` | `number` | `30` | Container log retention. |
| `log_kms_key_arn` | `string` | `null` | Optional log encryption key. |
| `alb_listener_arn` | `string` | `null` | Listener to attach a forward rule to. |
| `alb_security_group_id` | `string` | `null` | ALB security group allowed to reach tasks. |
| `alb_arn_suffix` | `string` | `null` | ALB ARN suffix; required for request-count scaling. |
| `listener_rule_priority` | `number` | `100` | Listener rule priority. |
| `listener_host_headers` | `list(string)` | `[]` | Host headers routed to the service. |
| `listener_path_patterns` | `list(string)` | `[]` | Path patterns routed to the service. |
| `health_check_path` | `string` | `/` | Target group health check path. |
| `health_check_matcher` | `string` | `200-399` | Healthy HTTP codes. |
| `deregistration_delay` | `number` | `30` | Target draining delay (seconds). |
| `desired_count` | `number` | `2` | Initial desired task count. |
| `platform_version` | `string` | `LATEST` | Fargate platform version. |
| `capacity_provider_strategy` | `list(object)` | `[]` | Optional Spot/on-demand strategy. |
| `health_check_grace_period_seconds` | `number` | `60` | Health check grace period. |
| `enable_execute_command` | `bool` | `true` | Enable ECS Exec. |
| `enable_deployment_circuit_breaker` | `bool` | `true` | Roll back failed rolling deploys. |
| `deployment_minimum_healthy_percent` | `number` | `100` | Min healthy tasks during deploy. |
| `deployment_maximum_percent` | `number` | `200` | Max running tasks during deploy. |
| `additional_security_group_ids` | `list(string)` | `[]` | Extra task security groups. |
| `min_capacity` | `number` | `2` | Autoscaling floor. |
| `max_capacity` | `number` | `10` | Autoscaling ceiling. |
| `cpu_target_value` | `number` | `60` | Target CPU utilization percentage. |
| `memory_target_value` | `number` | `null` | Target memory percentage (null disables). |
| `request_count_target` | `number` | `null` | Target requests per task (null disables). |
| `scale_in_cooldown` | `number` | `300` | Scale-in cooldown (seconds). |
| `scale_out_cooldown` | `number` | `60` | Scale-out cooldown (seconds). |
| `tags` | `map(string)` | `{}` | Extra tags. |

## Outputs

| Name | Description |
|------|-------------|
| `service_name` | Name of the ECS service. |
| `service_id` | ARN/ID of the ECS service. |
| `task_definition_arn` | Active task definition revision ARN. |
| `task_definition_family` | Task definition family name. |
| `target_group_arn` | Target group ARN. |
| `target_group_arn_suffix` | Target group ARN suffix. |
| `security_group_id` | Task security group ID. |
| `task_role_arn` | Application task role ARN. |
| `execution_role_arn` | Task execution role ARN. |
| `log_group_name` | Container log group name. |
| `autoscaling_target_resource_id` | Application Auto Scaling resource id. |
| `listener_rule_arn` | Listener rule ARN (or null). |
