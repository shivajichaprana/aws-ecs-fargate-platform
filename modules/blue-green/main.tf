# Blue/green deployments for an ECS service.
#
# Shifts traffic between two target groups instead of replacing tasks in place.
# A deployment stands up a replacement task set alongside the running one, lets
# it be validated on an optional test listener, then moves production traffic
# across all at once, linearly, or as a canary. The original task set is kept
# running for a configurable window so a rollback is a traffic swap rather than
# a redeploy, and CloudWatch alarms on the replacement target group stop and
# reverse a rollout that starts erroring.
#
# This module pairs with a service that uses the CODE_DEPLOY deployment
# controller: the service defines the two target groups, this module owns the
# listeners, traffic shifting, and rollback policy.

locals {
  base_name = "${var.name_prefix}-${var.service_name}-${var.environment}"

  create_role      = var.codedeploy_role_arn == null
  codedeploy_role  = local.create_role ? aws_iam_role.this[0].arn : var.codedeploy_role_arn
  create_listeners = var.create_listeners

  # A test listener is only meaningful when there is somewhere to send test
  # traffic: either a managed listener on a supplied port, or caller-supplied
  # listener ARNs.
  create_test_listener = local.create_listeners && var.test_listener_port != null

  production_listener_arns = local.create_listeners ? aws_lb_listener.production[*].arn : var.production_listener_arns
  test_listener_arns       = local.create_listeners ? aws_lb_listener.test[*].arn : var.test_listener_arns

  # Alarms that stop and roll back an in-flight deployment. Module-managed alarms
  # watch the replacement target group; callers can add their own application or
  # SLO alarms to the same gate.
  managed_alarm_names = concat(
    aws_cloudwatch_metric_alarm.target_errors[*].alarm_name,
    aws_cloudwatch_metric_alarm.unhealthy_targets[*].alarm_name,
  )

  alarm_names = concat(local.managed_alarm_names, var.additional_alarm_names)

  # A listener protocol of HTTPS requires a certificate on every managed listener
  # that uses it.
  https_listener_requested = local.create_listeners && (
    var.production_listener_protocol == "HTTPS" ||
    (local.create_test_listener && var.test_listener_protocol == "HTTPS")
  )

  base_tags = merge(
    {
      Name        = local.base_name
      Environment = var.environment
      Service     = var.service_name
    },
    var.tags,
  )
}

# --- IAM ----------------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  count = local.create_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

# Service role CodeDeploy assumes to register task sets, modify listeners, and
# read the ECS service. The AWS-managed policy is scoped to exactly these
# actions, so no inline permissions are added.
resource "aws_iam_role" "this" {
  count = local.create_role ? 1 : 0

  name                 = "${local.base_name}-deploy"
  assume_role_policy   = data.aws_iam_policy_document.assume_role[0].json
  max_session_duration = 3600

  tags = local.base_tags
}

resource "aws_iam_role_policy_attachment" "ecs" {
  count = local.create_role ? 1 : 0

  role       = aws_iam_role.this[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

# --- Listeners ----------------------------------------------------------------

# Production listener. Its default action is swapped between the two target
# groups during a deployment, so the action is managed outside Terraform once the
# listener exists; only the initial value is declared here.
resource "aws_lb_listener" "production" {
  count = local.create_listeners ? 1 : 0

  load_balancer_arn = var.load_balancer_arn
  port              = var.production_listener_port
  protocol          = var.production_listener_protocol
  certificate_arn   = var.production_listener_protocol == "HTTPS" ? var.certificate_arn : null
  ssl_policy        = var.production_listener_protocol == "HTTPS" ? var.ssl_policy : null

  default_action {
    type             = "forward"
    target_group_arn = var.blue_target_group_arn
  }

  tags = merge(local.base_tags, { Name = "${local.base_name}-prod" })

  lifecycle {
    ignore_changes = [default_action]

    precondition {
      condition     = var.load_balancer_arn != null && var.blue_target_group_arn != null
      error_message = "load_balancer_arn and blue_target_group_arn are required when create_listeners is true."
    }
    precondition {
      condition     = var.production_listener_protocol != "HTTPS" || var.certificate_arn != null
      error_message = "certificate_arn is required when a managed listener uses HTTPS."
    }
  }
}

# Test listener. Traffic sent here reaches the replacement task set before any
# production traffic is shifted, which is where smoke tests run.
resource "aws_lb_listener" "test" {
  count = local.create_test_listener ? 1 : 0

  load_balancer_arn = var.load_balancer_arn
  port              = var.test_listener_port
  protocol          = var.test_listener_protocol
  certificate_arn   = var.test_listener_protocol == "HTTPS" ? var.certificate_arn : null
  ssl_policy        = var.test_listener_protocol == "HTTPS" ? var.ssl_policy : null

  default_action {
    type             = "forward"
    target_group_arn = var.blue_target_group_arn
  }

  tags = merge(local.base_tags, { Name = "${local.base_name}-test" })

  lifecycle {
    ignore_changes = [default_action]

    precondition {
      condition     = var.test_listener_protocol != "HTTPS" || var.certificate_arn != null
      error_message = "certificate_arn is required when a managed listener uses HTTPS."
    }
  }
}

# --- Rollback alarms ----------------------------------------------------------

# Server errors on the replacement target group. Breaching this while traffic is
# shifting stops the deployment and reverses it.
resource "aws_cloudwatch_metric_alarm" "target_errors" {
  count = var.enable_rollback_alarms ? 1 : 0

  alarm_name        = "${local.base_name}-rollout-target-errors"
  alarm_description = "Server errors from the replacement task set during a deployment."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.error_count_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"

  # No data means no traffic has reached the replacement task set yet, which is
  # not a failure signal.
  treat_missing_data = "notBreaching"

  dimensions = {
    LoadBalancer = var.load_balancer_arn_suffix
    TargetGroup  = var.green_target_group_arn_suffix
  }

  tags = local.base_tags

  lifecycle {
    precondition {
      condition     = var.load_balancer_arn_suffix != null && var.green_target_group_arn_suffix != null
      error_message = "load_balancer_arn_suffix and green_target_group_arn_suffix are required when enable_rollback_alarms is true."
    }
  }
}

# Targets in the replacement group that never pass health checks.
resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  count = var.enable_rollback_alarms ? 1 : 0

  alarm_name        = "${local.base_name}-rollout-unhealthy-targets"
  alarm_description = "Replacement task set has targets failing load balancer health checks."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  treat_missing_data = "notBreaching"

  dimensions = {
    LoadBalancer = var.load_balancer_arn_suffix
    TargetGroup  = var.green_target_group_arn_suffix
  }

  tags = local.base_tags
}

# --- CodeDeploy ---------------------------------------------------------------

resource "aws_codedeploy_app" "this" {
  name             = local.base_name
  compute_platform = "ECS"

  tags = local.base_tags
}

resource "aws_codedeploy_deployment_group" "this" {
  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = local.base_name
  service_role_arn       = local.codedeploy_role
  deployment_config_name = var.deployment_config_name

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  blue_green_deployment_config {
    # Either shift traffic as soon as the replacement task set is healthy, or
    # hold it behind the test listener until rerouting is approved.
    deployment_ready_option {
      action_on_timeout    = var.require_manual_traffic_rerouting ? "STOP_DEPLOYMENT" : "CONTINUE_DEPLOYMENT"
      wait_time_in_minutes = var.require_manual_traffic_rerouting ? var.traffic_rerouting_wait_time_in_minutes : 0
    }

    # Keep the original task set running after the shift so a rollback is a
    # traffic swap rather than a redeploy.
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = var.termination_wait_time_in_minutes
    }
  }

  ecs_service {
    cluster_name = var.cluster_name
    service_name = var.ecs_service_name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = local.production_listener_arns
      }

      dynamic "test_traffic_route" {
        for_each = length(local.test_listener_arns) > 0 ? [1] : []
        content {
          listener_arns = local.test_listener_arns
        }
      }

      target_group {
        name = var.blue_target_group_name
      }

      target_group {
        name = var.green_target_group_name
      }
    }
  }

  auto_rollback_configuration {
    enabled = length(var.auto_rollback_events) > 0
    events  = var.auto_rollback_events
  }

  alarm_configuration {
    enabled                   = length(local.alarm_names) > 0
    alarms                    = local.alarm_names
    ignore_poll_alarm_failure = var.ignore_poll_alarm_failure
  }

  dynamic "trigger_configuration" {
    for_each = var.notification_sns_topic_arn != null ? [1] : []
    content {
      trigger_name       = "${local.base_name}-deployment"
      trigger_target_arn = var.notification_sns_topic_arn
      trigger_events     = var.notification_events
    }
  }

  tags = local.base_tags

  lifecycle {
    precondition {
      condition     = length(local.production_listener_arns) > 0
      error_message = "Provide production_listener_arns, or set create_listeners to true so the module manages the production listener."
    }
    precondition {
      condition     = var.blue_target_group_name != var.green_target_group_name
      error_message = "blue_target_group_name and green_target_group_name must differ."
    }
    precondition {
      condition     = !var.require_manual_traffic_rerouting || length(local.test_listener_arns) > 0
      error_message = "Manual traffic rerouting requires a test listener so the replacement task set can be validated before approval."
    }
    precondition {
      condition     = !local.https_listener_requested || var.certificate_arn != null
      error_message = "certificate_arn is required when a managed listener uses HTTPS."
    }
  }
}
