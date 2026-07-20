# Service onboarding guide

This guide walks a team through bringing a new containerized service onto the
platform, from a bare image to an autoscaled, load-balanced, observable
deployment.

## Prerequisites

- A container image in a registry reachable by ECS (ECR recommended).
- The platform cluster applied (`modules/ecs-cluster`), with its
  `cluster_arn` and `cluster_name` outputs available.
- A VPC with private subnets, and — for internet-facing services — an ALB with
  a listener and security group you can reference.
- Terraform `>= 1.6.0` with AWS credentials for the target account.

## 1. Declare the service

Start from the minimal call and add features as needed:

```hcl
module "orders" {
  source = "./modules/service"

  name_prefix  = "ecs-platform"
  service_name = "orders"
  environment  = "prod"

  cluster_arn  = module.cluster.cluster_arn
  cluster_name = module.cluster.cluster_name

  vpc_id     = "<your-vpc-id>"
  subnet_ids = ["<private-subnet-a>", "<private-subnet-b>"]

  container_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/orders:2.1.0"
  container_port  = 8080
  cpu             = 512
  memory          = 1024

  container_environment = {
    APP_ENV   = "prod"
    HTTP_PORT = "8080"
  }
}
```

Pick a valid Fargate `cpu`/`memory` pair (for example 256/512, 512/1024,
1024/2048); invalid combinations are rejected at plan time. Set
`cpu_architecture = "ARM64"` for Graviton if your image is multi-arch.

## 2. Expose it through the ALB

Attach the service to an existing listener with a rule:

```hcl
  alb_listener_arn       = "<your-listener-arn>"
  alb_security_group_id  = "<your-alb-sg-id>"
  listener_rule_priority = 120
  listener_path_patterns = ["/orders/*"]

  health_check_path    = "/healthz"
  health_check_matcher = "200"
```

The module creates the target group, the listener rule (host-header and/or
path-pattern conditions — at least one is required), and a security-group
ingress rule admitting only the ALB. Skip these inputs entirely for internal
services that are reached via Service Connect.

## 3. Inject configuration and secrets

Reference secrets instead of embedding them:

```hcl
  container_secrets = {
    DATABASE_URL = "arn:aws:secretsmanager:us-east-1:123456789012:secret:orders/db-url-AbCdEf"
    API_KEY      = "arn:aws:ssm:us-east-1:123456789012:parameter/orders/api-key"
  }

  secrets_manager_secret_arns = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:orders/*"]
  ssm_parameter_arns          = ["arn:aws:ssm:us-east-1:123456789012:parameter/orders/*"]
```

The execution role receives a scoped inline policy for exactly these ARNs
(plus `kms:Decrypt` on any `secrets_kms_key_arns` you list for customer-managed
keys). A precondition rejects `container_secrets` without a matching source ARN
when the module manages the execution role.

## 4. Join the service mesh (optional)

Create the namespace once, wire it into the cluster, then opt services in:

```hcl
module "mesh" {
  source      = "./modules/service-connect"
  name_prefix = "ecs-platform"
  environment = "prod"
}

# In modules/ecs-cluster:
#   service_connect_namespace_arn = module.mesh.namespace_arn

# In the service call:
  service_connect_namespace = module.mesh.namespace_name
  service_connect_alias     = "orders"   # peers call http://orders:8080
```

Other services in the namespace reach this one at its client alias; no public
DNS records are created. Use `service_connect_peer_security_group_id` to admit
mesh callers that live behind a different security group.

## 5. Tune autoscaling

```hcl
  min_capacity     = 2
  max_capacity     = 12
  cpu_target_value = 55

  # Optional additional dimensions:
  memory_target_value  = 70
  request_count_target = 400   # requires alb_arn_suffix
```

Target tracking adds capacity when the metric runs hot and removes it after the
scale-in cooldown. Keep `min_capacity >= 2` for anything user-facing so a
single task failure never takes the service to zero.

## 6. Choose a rollout strategy

Rolling with circuit breaker is the default and needs no extra wiring. For
blue/green:

```hcl
# In the service call:
  deployment_controller_type = "CODE_DEPLOY"

module "orders_bluegreen" {
  source = "./modules/blue-green"

  name_prefix  = "ecs-platform"
  service_name = "orders"
  environment  = "prod"

  cluster_name     = module.cluster.cluster_name
  ecs_service_name = module.orders.service_name

  blue_target_group_name  = module.orders.target_group_name
  green_target_group_name = module.orders.green_target_group_name
  container_name          = module.orders.container_name
  container_port          = 8080

  create_listeners  = true
  load_balancer_arn = "<your-alb-arn>"
  certificate_arn   = "<your-acm-cert-arn>"

  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"

  enable_rollback_alarms        = true
  load_balancer_arn_suffix      = "<your-alb-arn-suffix>"
  green_target_group_arn_suffix = module.orders.green_target_group_arn_suffix
}
```

In `CODE_DEPLOY` mode the blue-green module owns the listeners (CodeDeploy
swaps them at deployment time), so do not also set `alb_listener_arn` on the
service — a precondition rejects that combination. Feed the `appspec_yaml`
output to your pipeline and substitute the `<TASK_DEFINITION>` placeholder with
each new revision ARN.

## 7. Verify

- `make validate test` before review; CI runs the same checks.
- After apply: confirm target group health, then `aws ecs execute-command`
  (sessions are KMS-encrypted and logged) for a shell inside a task if needed.
- Watch the service dashboard in Container Insights for CPU, memory, and task
  restart trends during the first traffic ramp.

## Onboarding checklist

- [ ] Valid Fargate CPU/memory pair chosen
- [ ] Health check endpoint returns 200 without auth
- [ ] Secrets referenced by ARN, none in plain environment variables
- [ ] ALB exposure or Service Connect alias decided (or both)
- [ ] Autoscaling bounds and targets reviewed with the service owner
- [ ] Rollout strategy chosen; blue/green wired if required
- [ ] `make validate test lint` clean
