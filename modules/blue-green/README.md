# blue-green module

Shifts traffic between two target groups instead of replacing tasks in place.
A deployment stands up a replacement task set alongside the running one, lets it
be validated on an optional test listener, then moves production traffic across
all at once, linearly, or as a canary. The original task set stays running for a
configurable window, so a rollback is a traffic swap rather than a redeploy.

Pairs with the [`service`](../service) module configured with
`deployment_controller_type = "CODE_DEPLOY"`: the service owns the two target
groups, this module owns the listeners, traffic shifting, and rollback policy.

## What it creates

- `aws_codedeploy_app` and `aws_codedeploy_deployment_group` for the ECS compute
  platform, with a blue/green deployment style and traffic control.
- An IAM service role with the AWS-managed ECS deployment policy. That policy is
  already scoped to registering task sets and modifying listeners, so no inline
  permissions are added. Bring your own role with `codedeploy_role_arn`.
- Optional dedicated production and test `aws_lb_listener` resources. Their
  default actions are swapped by the deployment controller at deploy time, so
  Terraform declares only the initial value and then ignores changes to it.
- Optional CloudWatch alarms on the replacement target group — server errors and
  targets failing health checks — wired into the deployment group so a bad
  rollout stops and reverses automatically.
- Optional SNS notifications on deployment success, failure, and rollback.

## How a rollout progresses

1. The pipeline starts a deployment with a new task definition revision, using
   the rendered `appspec_yaml` output.
2. A replacement task set is created and registered into the replacement target
   group.
3. If a test listener is configured, the replacement task set is reachable there
   while production traffic still goes to the original task set. Smoke tests run
   against that listener.
4. Production traffic shifts according to `deployment_config_name` — all at once,
   in linear increments, or as a canary.
5. Rollback alarms are evaluated throughout. A breach stops the deployment and
   returns traffic to the original task set.
6. After a successful shift, the original task set is kept for
   `termination_wait_time_in_minutes` so a rollback stays instant, then removed.

## Usage

Let the module own dedicated production and test listeners on a shared ALB:

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

  # Create the replacement target group and hand rollouts to the controller.
  deployment_controller_type = "CODE_DEPLOY"
  alb_security_group_id      = var.alb_security_group_id
}

module "checkout_deploy" {
  source = "../../modules/blue-green"

  name_prefix  = "ecs-platform"
  service_name = "checkout"
  environment  = "prod"

  cluster_name     = module.cluster.cluster_name
  ecs_service_name = module.checkout.service_name

  blue_target_group_name  = module.checkout.target_group_name
  green_target_group_name = module.checkout.green_target_group_name
  container_name          = module.checkout.container_name
  container_port          = 8080

  # Manage a production listener on 443 and a test listener on 8443.
  create_listeners      = true
  load_balancer_arn     = var.alb_arn
  blue_target_group_arn = module.checkout.target_group_arn
  test_listener_port    = 8443
  certificate_arn       = var.certificate_arn

  # Shift 10% of traffic, hold for five minutes, then complete.
  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"

  # Roll back on target errors, unhealthy targets, or a breached SLO alarm.
  load_balancer_arn_suffix      = var.alb_arn_suffix
  green_target_group_arn_suffix = module.checkout.green_target_group_arn_suffix
  additional_alarm_names        = [var.checkout_latency_alarm_name]

  notification_sns_topic_arn = var.deploy_notifications_topic_arn
}
```

Require sign-off before production traffic moves, and keep the previous task set
for a longer rollback window:

```hcl
module "checkout_deploy" {
  source = "../../modules/blue-green"

  # ... identity, service, and target group inputs as above ...

  require_manual_traffic_rerouting       = true
  traffic_rerouting_wait_time_in_minutes = 120
  termination_wait_time_in_minutes       = 60
}
```

Attach to listeners that already exist rather than creating them:

```hcl
module "checkout_deploy" {
  source = "../../modules/blue-green"

  # ... identity, service, and target group inputs as above ...

  create_listeners         = false
  production_listener_arns = [var.https_listener_arn]
  test_listener_arns       = [var.test_listener_arn]
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | `string` | — | Platform prefix shared by all services. |
| `service_name` | `string` | — | Service this deployment group shifts traffic for. |
| `environment` | `string` | `dev` | Environment identifier. |
| `cluster_name` | `string` | — | ECS cluster hosting the service. |
| `ecs_service_name` | `string` | — | ECS service name; must use the `CODE_DEPLOY` controller. |
| `blue_target_group_name` | `string` | — | Target group serving production traffic. |
| `green_target_group_name` | `string` | — | Replacement target group traffic shifts to. |
| `container_name` | `string` | — | Container the load balancer routes to (for the AppSpec). |
| `container_port` | `number` | — | Container port the load balancer routes to. |
| `create_listeners` | `bool` | `false` | Create dedicated production/test listeners on the supplied ALB. |
| `load_balancer_arn` | `string` | `null` | ALB for managed listeners. Required when `create_listeners`. |
| `blue_target_group_arn` | `string` | `null` | Initial default action for managed listeners. Required when `create_listeners`. |
| `production_listener_arns` | `list(string)` | `[]` | Existing production listeners, when not creating them. |
| `test_listener_arns` | `list(string)` | `[]` | Existing test listeners, when not creating them. |
| `production_listener_port` | `number` | `443` | Port for the managed production listener. |
| `production_listener_protocol` | `string` | `HTTPS` | `HTTP` or `HTTPS`. |
| `test_listener_port` | `number` | `null` | Managed test listener port; null creates no test listener. |
| `test_listener_protocol` | `string` | `HTTPS` | `HTTP` or `HTTPS`. |
| `certificate_arn` | `string` | `null` | ACM certificate for managed HTTPS listeners. |
| `ssl_policy` | `string` | `ELBSecurityPolicy-TLS13-1-2-2021-06` | TLS policy for managed HTTPS listeners. |
| `deployment_config_name` | `string` | `CodeDeployDefault.ECSCanary10Percent5Minutes` | Traffic-shifting configuration. |
| `require_manual_traffic_rerouting` | `bool` | `false` | Hold behind the test listener until rerouting is approved. |
| `traffic_rerouting_wait_time_in_minutes` | `number` | `60` | Approval window before the deployment stops. |
| `termination_wait_time_in_minutes` | `number` | `15` | Rollback window before the original task set is removed. |
| `auto_rollback_events` | `list(string)` | `["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]` | Events triggering automatic rollback. |
| `enable_rollback_alarms` | `bool` | `true` | Create and wire in target-group rollback alarms. |
| `load_balancer_arn_suffix` | `string` | `null` | ALB ARN suffix; required when rollback alarms are enabled. |
| `green_target_group_arn_suffix` | `string` | `null` | Replacement target group ARN suffix; required when rollback alarms are enabled. |
| `error_count_threshold` | `number` | `5` | Target 5xx responses per period that mark a rollout unhealthy. |
| `alarm_period_seconds` | `number` | `60` | Alarm evaluation period. |
| `alarm_evaluation_periods` | `number` | `1` | Periods an alarm must breach before firing. |
| `additional_alarm_names` | `list(string)` | `[]` | Existing alarms that also gate the rollout. |
| `ignore_poll_alarm_failure` | `bool` | `false` | Continue when alarm state cannot be polled. |
| `notification_sns_topic_arn` | `string` | `null` | SNS topic for deployment lifecycle events. |
| `notification_events` | `list(string)` | `["DeploymentSuccess", "DeploymentFailure", "DeploymentRollback"]` | Events published to the topic. |
| `codedeploy_role_arn` | `string` | `null` | Bring-your-own service role; created when null. |
| `tags` | `map(string)` | `{}` | Extra tags. |

## Outputs

| Name | Description |
|------|-------------|
| `application_name` | CodeDeploy application name. |
| `deployment_group_name` | Deployment group name. |
| `deployment_config_name` | Traffic-shifting configuration in use. |
| `service_role_arn` | Service role CodeDeploy assumes. |
| `production_listener_arns` | Listeners swapped during a deployment. |
| `test_listener_arns` | Listeners serving the replacement task set before the shift. |
| `rollback_alarm_names` | Alarms that stop and roll back a deployment. |
| `appspec_yaml` | Rendered AppSpec for the delivery pipeline. |

## Notes

- The service must be created with `deployment_controller_type = "CODE_DEPLOY"`.
  Switching an existing service between rollout modes replaces it.
- Traffic shifting swaps a listener's default action, so a listener dedicated to
  the service is required. Host- and path-based listener rules stay pinned to one
  target group and are therefore only available for in-place rollouts.
- Image promotion belongs to the delivery pipeline: the pipeline supplies the new
  task definition revision in the AppSpec, and Terraform does not track which
  revision is currently deployed.
