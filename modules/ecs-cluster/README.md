# ecs-cluster module

Provisions a Fargate ECS cluster foundation: capacity providers, Container
Insights, and an encrypted, auditable ECS Exec trail.

## What it creates

- `aws_ecs_cluster` with Container Insights and, optionally, an
  `execute_command_configuration` that encrypts ECS Exec sessions with KMS and
  streams session activity to a dedicated CloudWatch log group.
- `aws_ecs_cluster_capacity_providers` associating `FARGATE` and
  `FARGATE_SPOT` with a configurable default strategy.
- An optional module-managed KMS key (with rotation) and CloudWatch log group
  for ECS Exec, created only when a key is not supplied.

## Usage

```hcl
module "cluster" {
  source = "../../modules/ecs-cluster"

  name_prefix = "ecs-platform"
  environment = "prod"

  container_insights = "enhanced"

  default_capacity_provider_strategy = [
    { capacity_provider = "FARGATE",      base = 1, weight = 1 },
    { capacity_provider = "FARGATE_SPOT", base = 0, weight = 4 },
  ]
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | `string` | — | Prefix for cluster resource names. |
| `environment` | `string` | `dev` | Environment identifier. |
| `container_insights` | `string` | `enabled` | `enabled`, `enhanced`, or `disabled`. |
| `capacity_providers` | `list(string)` | `["FARGATE","FARGATE_SPOT"]` | Fargate providers to associate. |
| `default_capacity_provider_strategy` | `list(object)` | Fargate base + Spot weight | Default placement strategy. |
| `enable_execute_command_logging` | `bool` | `true` | Encrypt and audit ECS Exec sessions. |
| `log_retention_in_days` | `number` | `90` | ECS Exec log retention. |
| `kms_key_arn` | `string` | `null` | Bring-your-own KMS key; module creates one when null. |
| `tags` | `map(string)` | `{}` | Extra tags. |

## Outputs

| Name | Description |
|------|-------------|
| `cluster_arn` | ARN of the ECS cluster. |
| `cluster_id` | ID of the ECS cluster. |
| `cluster_name` | Name of the ECS cluster. |
| `capacity_providers` | Associated capacity providers. |
| `exec_log_group_name` | ECS Exec audit log group name (or null). |
| `exec_kms_key_arn` | ECS Exec encryption key ARN (or null). |
