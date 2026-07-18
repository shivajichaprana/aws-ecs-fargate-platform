# --- Identity -----------------------------------------------------------------

variable "name_prefix" {
  description = "Platform prefix shared by all services (for example ecs-platform)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with hyphens, 3-20 characters, and start with a letter."
  }
}

variable "service_name" {
  description = "Short name of the service this deployment group shifts traffic for."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,18}[a-z0-9]$", var.service_name))
    error_message = "service_name must be lowercase alphanumeric with hyphens, 2-20 characters, and start with a letter."
  }
}

variable "environment" {
  description = "Environment identifier (for example dev, staging, or prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# --- Deployment target --------------------------------------------------------

variable "cluster_name" {
  description = "Name of the ECS cluster hosting the service."
  type        = string
}

variable "ecs_service_name" {
  description = "Name of the ECS service. The service must use the CODE_DEPLOY deployment controller."
  type        = string
}

variable "blue_target_group_name" {
  description = "Name of the target group currently serving production traffic."
  type        = string
}

variable "green_target_group_name" {
  description = "Name of the replacement target group traffic is shifted to during a deployment."
  type        = string
}

variable "container_name" {
  description = "Container name the load balancer routes to, used to render the deployment AppSpec."
  type        = string
}

variable "container_port" {
  description = "Container port the load balancer routes to, used to render the deployment AppSpec."
  type        = number

  validation {
    condition     = var.container_port > 0 && var.container_port <= 65535
    error_message = "container_port must be between 1 and 65535."
  }
}

# --- Traffic routing ----------------------------------------------------------

variable "create_listeners" {
  description = "Create dedicated production and test listeners on the supplied ALB. When false, listener ARNs must be supplied instead."
  type        = bool
  default     = false
}

variable "load_balancer_arn" {
  description = "ARN of the load balancer the managed listeners are attached to. Required when create_listeners is true."
  type        = string
  default     = null
}

variable "blue_target_group_arn" {
  description = "ARN of the production target group, used as the initial default action of the managed listeners. Required when create_listeners is true."
  type        = string
  default     = null
}

variable "production_listener_arns" {
  description = "Existing production listener ARNs whose default action is swapped between the two target groups. Ignored when create_listeners is true."
  type        = list(string)
  default     = []
}

variable "test_listener_arns" {
  description = "Existing test listener ARNs used to validate the replacement task set before production traffic shifts. Ignored when create_listeners is true."
  type        = list(string)
  default     = []
}

variable "production_listener_port" {
  description = "Port for the managed production listener."
  type        = number
  default     = 443

  validation {
    condition     = var.production_listener_port > 0 && var.production_listener_port <= 65535
    error_message = "production_listener_port must be between 1 and 65535."
  }
}

variable "production_listener_protocol" {
  description = "Protocol for the managed production listener."
  type        = string
  default     = "HTTPS"

  validation {
    condition     = contains(["HTTP", "HTTPS"], var.production_listener_protocol)
    error_message = "production_listener_protocol must be HTTP or HTTPS."
  }
}

variable "test_listener_port" {
  description = "Port for the managed test listener. When null, no test listener is created and deployments shift straight to production traffic."
  type        = number
  default     = null

  validation {
    condition     = var.test_listener_port == null || (coalesce(var.test_listener_port, 1) > 0 && coalesce(var.test_listener_port, 1) <= 65535)
    error_message = "test_listener_port must be between 1 and 65535."
  }
}

variable "test_listener_protocol" {
  description = "Protocol for the managed test listener."
  type        = string
  default     = "HTTPS"

  validation {
    condition     = contains(["HTTP", "HTTPS"], var.test_listener_protocol)
    error_message = "test_listener_protocol must be HTTP or HTTPS."
  }
}

variable "certificate_arn" {
  description = "ACM certificate ARN for managed HTTPS listeners. Required when a managed listener uses HTTPS."
  type        = string
  default     = null
}

variable "ssl_policy" {
  description = "TLS security policy applied to managed HTTPS listeners."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

# --- Deployment behaviour -----------------------------------------------------

variable "deployment_config_name" {
  description = "Traffic-shifting configuration. Built-in options shift all at once, linearly, or as a canary; a custom deployment configuration name may also be supplied."
  type        = string
  default     = "CodeDeployDefault.ECSCanary10Percent5Minutes"

  validation {
    condition = (
      !startswith(var.deployment_config_name, "CodeDeployDefault.") ||
      contains([
        "CodeDeployDefault.ECSAllAtOnce",
        "CodeDeployDefault.ECSLinear10PercentEvery1Minutes",
        "CodeDeployDefault.ECSLinear10PercentEvery3Minutes",
        "CodeDeployDefault.ECSCanary10Percent5Minutes",
        "CodeDeployDefault.ECSCanary10Percent15Minutes",
      ], var.deployment_config_name)
    )
    error_message = "Built-in deployment configurations must be one of the ECS variants: CodeDeployDefault.ECSAllAtOnce, CodeDeployDefault.ECSLinear10PercentEvery1Minutes, CodeDeployDefault.ECSLinear10PercentEvery3Minutes, CodeDeployDefault.ECSCanary10Percent5Minutes, CodeDeployDefault.ECSCanary10Percent15Minutes."
  }
}

variable "require_manual_traffic_rerouting" {
  description = "Hold the replacement task set behind the test listener until traffic rerouting is approved, instead of shifting automatically once it is healthy."
  type        = bool
  default     = false
}

variable "traffic_rerouting_wait_time_in_minutes" {
  description = "How long to wait for manual approval before the deployment is stopped. Applies only when manual traffic rerouting is required."
  type        = number
  default     = 60

  validation {
    condition     = var.traffic_rerouting_wait_time_in_minutes >= 0 && var.traffic_rerouting_wait_time_in_minutes <= 2880
    error_message = "traffic_rerouting_wait_time_in_minutes must be between 0 and 2880 (48 hours)."
  }
}

variable "termination_wait_time_in_minutes" {
  description = "How long the original task set is kept running after a successful shift, providing a fast rollback window before it is terminated."
  type        = number
  default     = 15

  validation {
    condition     = var.termination_wait_time_in_minutes >= 0 && var.termination_wait_time_in_minutes <= 2880
    error_message = "termination_wait_time_in_minutes must be between 0 and 2880 (48 hours)."
  }
}

variable "auto_rollback_events" {
  description = "Events that trigger an automatic rollback to the original task set. An empty list disables automatic rollback."
  type        = list(string)
  default     = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]

  validation {
    condition = length(setsubtract(
      var.auto_rollback_events,
      ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM", "DEPLOYMENT_STOP_ON_REQUEST"],
    )) == 0
    error_message = "auto_rollback_events may only contain DEPLOYMENT_FAILURE, DEPLOYMENT_STOP_ON_ALARM, and DEPLOYMENT_STOP_ON_REQUEST."
  }
}

# --- Rollback alarms ----------------------------------------------------------

variable "enable_rollback_alarms" {
  description = "Create CloudWatch alarms on the replacement target group and wire them into the deployment group so a bad rollout is rolled back automatically."
  type        = bool
  default     = true
}

variable "load_balancer_arn_suffix" {
  description = "ARN suffix of the load balancer (app/name/id), used as an alarm dimension. Required when rollback alarms are enabled."
  type        = string
  default     = null
}

variable "green_target_group_arn_suffix" {
  description = "ARN suffix of the replacement target group (targetgroup/name/id), used as an alarm dimension. Required when rollback alarms are enabled."
  type        = string
  default     = null
}

variable "error_count_threshold" {
  description = "Number of target 5xx responses in a single evaluation period that marks the rollout unhealthy."
  type        = number
  default     = 5

  validation {
    condition     = var.error_count_threshold > 0
    error_message = "error_count_threshold must be greater than zero."
  }
}

variable "alarm_period_seconds" {
  description = "Evaluation period for the rollback alarms."
  type        = number
  default     = 60
}

variable "alarm_evaluation_periods" {
  description = "Consecutive periods an alarm must breach before it fires."
  type        = number
  default     = 1
}

variable "additional_alarm_names" {
  description = "Existing CloudWatch alarm names that should also stop and roll back a deployment (for example an application SLO alarm)."
  type        = list(string)
  default     = []
}

variable "ignore_poll_alarm_failure" {
  description = "Continue a deployment when CloudWatch alarm state cannot be polled. Keeping this false fails closed."
  type        = bool
  default     = false
}

# --- Notifications and IAM ----------------------------------------------------

variable "notification_sns_topic_arn" {
  description = "Optional SNS topic notified about deployment lifecycle events. When null, no trigger is configured."
  type        = string
  default     = null
}

variable "notification_events" {
  description = "Deployment lifecycle events published to the notification topic."
  type        = list(string)
  default     = ["DeploymentSuccess", "DeploymentFailure", "DeploymentRollback"]
}

variable "codedeploy_role_arn" {
  description = "Existing service role ARN for CodeDeploy. When null, the module creates one with the AWS-managed ECS deployment policy."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags applied to all deployment resources."
  type        = map(string)
  default     = {}
}
