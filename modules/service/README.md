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
- `aws_ecs_service` — wired to the target group, in one of two rollout modes.
  In-place rollouts replace tasks gradually behind a circuit breaker that rolls
  back a deployment which never stabilizes. Traffic-shifting rollouts hand the
  active revision and traffic routing to an external deployment controller.
  Autoscaling owns `desired_count` in both modes.
- `aws_lb_target_group` (target type `ip`), plus a second replacement target
  group for traffic-shifting rollouts, and an optional `aws_lb_listener_rule`
  with host-header and/or path-pattern conditions.
- `aws_security_group` for the task ENIs, allowing inbound traffic only from the
  ALB security group on the container port.
- Least-privilege IAM roles (execution + task). The task role gains only the SSM
  messaging permissions required for ECS Exec, and only when Exec is enabled.
- Optional ECS Service Connect registration: a named port mapping, a client
  alias, and proxy logging, so peers reach the service by a short alias over an
  encrypted mesh. The execution role gains scoped read access to the specific
  Secrets Manager secrets and SSM parameters injected into the task definition.
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

Register the service into a Service Connect namespace and inject credentials
from Secrets Manager and SSM Parameter Store:

```hcl
module "checkout" {
  source = "../../modules/service"

  name_prefix  = "ecs-platform"
  service_name = "checkout"
  environment  = "prod"

  cluster_arn  = module.cluster.cluster_arn
  cluster_name = module.cluster.cluster_name
  vpc_id       = var.vpc_id
  subnet_ids   = var.private_subnet_ids

  container_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/checkout:1.4.2"
  container_port  = 8080

  # Join the mesh; peers reach this service at http://checkout:8080.
  service_connect_namespace = module.service_connect.namespace_arn

  # Inject credentials at launch instead of baking them into the image.
  container_secrets = [
    { name = "DB_PASSWORD", value_from = var.db_password_secret_arn },
    { name = "API_KEY", value_from = var.api_key_parameter_arn },
  ]
  secrets_manager_secret_arns = [var.db_password_secret_arn]
  ssm_parameter_arns          = [var.api_key_parameter_arn]
  secrets_kms_key_arns        = [var.secrets_kms_key_arn]
}
```

## Rollout modes

`deployment_controller_type` selects how new revisions reach production.

| | `ECS` (default) | `CODE_DEPLOY` |
|---|---|---|
| Rollout | Tasks replaced in place within healthy-percent bounds | Replacement task set created, then traffic shifted |
| Target groups | One | Two — production and replacement |
| Rollback | Circuit breaker, after the deployment fails to stabilize | Traffic swap back, immediately |
| Pre-production validation | None | Optional test listener |
| Routing | Listener rule with host/path conditions | Dedicated listener owned by the deployment module |
| Revision owned by | Terraform | The delivery pipeline |

Traffic shifting swaps a listener's default action between the two target
groups, so it needs a listener dedicated to the service. Listener rules stay
pinned to a single target group and are therefore created only for in-place
rollouts; setting `alb_listener_arn` alongside `CODE_DEPLOY` is rejected by a
precondition. Pair that mode with the [`blue-green`](../blue-green) module, which
owns the listeners, the traffic-shifting configuration, and the rollback alarms:

```hcl
module "checkout" {
  source = "../../modules/service"

  # ... identity, cluster, network, and container inputs ...

  deployment_controller_type = "CODE_DEPLOY"
  alb_security_group_id      = var.alb_security_group_id
}

module "checkout_deploy" {
  source = "../../modules/blue-green"

  cluster_name     = module.cluster.cluster_name
  ecs_service_name = module.checkout.service_name

  blue_target_group_name  = module.checkout.target_group_name
  green_target_group_name = module.checkout.green_target_group_name
  container_name          = module.checkout.container_name
  container_port          = 8080

  # ... listener and rollback-alarm inputs ...
}
```

Switching an existing service between modes replaces it, because the two modes
declare different lifecycle rules and cannot share one resource.

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
| `deployment_controller_type` | `string` | `ECS` | Rollout mode: `ECS` in place, or `CODE_DEPLOY` traffic shifting. |
| `enable_deployment_circuit_breaker` | `bool` | `true` | Roll back failed in-place deploys. |
| `deployment_minimum_healthy_percent` | `number` | `100` | Min healthy tasks during an in-place deploy. |
| `deployment_maximum_percent` | `number` | `200` | Max running tasks during an in-place deploy. |
| `additional_security_group_ids` | `list(string)` | `[]` | Extra task security groups. |
| `min_capacity` | `number` | `2` | Autoscaling floor. |
| `max_capacity` | `number` | `10` | Autoscaling ceiling. |
| `cpu_target_value` | `number` | `60` | Target CPU utilization percentage. |
| `memory_target_value` | `number` | `null` | Target memory percentage (null disables). |
| `request_count_target` | `number` | `null` | Target requests per task (null disables). |
| `scale_in_cooldown` | `number` | `300` | Scale-in cooldown (seconds). |
| `scale_out_cooldown` | `number` | `60` | Scale-out cooldown (seconds). |
| `service_connect_namespace` | `string` | `null` | Cloud Map namespace ARN/name; enables Service Connect when set. |
| `service_connect_alias` | `string` | `null` | Alias peers use to reach the service (defaults to `service_name`). |
| `service_connect_discovery_name` | `string` | `null` | Discovery name in the namespace (defaults to `service_name`). |
| `service_connect_port_name` | `string` | `null` | Named port mapping exposed via Service Connect (defaults to `service_name`). |
| `service_connect_dns_port` | `number` | `null` | Client alias port (defaults to `container_port`). |
| `service_connect_app_protocol` | `string` | `http` | `http`, `http2`, or `grpc`. |
| `service_connect_peer_security_group_id` | `string` | `null` | Peer SG allowed east-west to the container port. |
| `enable_service_connect_logs` | `bool` | `true` | Stream Service Connect proxy logs to the log group. |
| `container_secrets` | `list(object)` | `[]` | Secrets injected as env vars (`name`, `value_from`). |
| `secrets_manager_secret_arns` | `list(string)` | `[]` | Secrets Manager ARNs the execution role may read. |
| `ssm_parameter_arns` | `list(string)` | `[]` | SSM parameter ARNs the execution role may read. |
| `secrets_kms_key_arns` | `list(string)` | `[]` | KMS keys the execution role may use to decrypt secrets. |
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
| `target_group_name` | Name of the target group serving production traffic. |
| `green_target_group_arn` | Replacement target group ARN (null for in-place rollouts). |
| `green_target_group_arn_suffix` | Replacement target group ARN suffix. |
| `green_target_group_name` | Replacement target group name (null for in-place rollouts). |
| `container_name` | Container name the load balancer routes to. |
| `deployment_controller_type` | Rollout mode the service was created with. |
| `security_group_id` | Task security group ID. |
| `task_role_arn` | Application task role ARN. |
| `execution_role_arn` | Task execution role ARN. |
| `log_group_name` | Container log group name. |
| `autoscaling_target_resource_id` | Application Auto Scaling resource id. |
| `listener_rule_arn` | Listener rule ARN (or null). |
| `service_connect_enabled` | Whether the service joined a Service Connect namespace. |
| `service_connect_endpoint` | Client endpoint `alias:port` for peers (or null). |
