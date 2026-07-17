# --- Identity and placement ---------------------------------------------------

variable "name_prefix" {
  description = "Platform prefix shared by all services (for example ecs-platform)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with hyphens, 3-20 characters, and start with a letter."
  }
}

variable "service_name" {
  description = "Short name of this service, unique within the platform (for example checkout)."
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

variable "cluster_arn" {
  description = "ARN of the ECS cluster the service runs in."
  type        = string
}

variable "cluster_name" {
  description = "Name of the ECS cluster, used to build the Application Auto Scaling resource id."
  type        = string
}

variable "vpc_id" {
  description = "VPC the target group and task security group are created in."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets the tasks are placed in. Use private subnets for internet-facing services fronted by a public ALB."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids must contain at least one subnet."
  }
}

variable "assign_public_ip" {
  description = "Assign a public IP to tasks. Keep false when tasks run in private subnets behind an ALB."
  type        = bool
  default     = false
}

# --- Container and task definition --------------------------------------------

variable "container_image" {
  description = "Fully qualified container image reference (for example an ECR image URI with a tag or digest)."
  type        = string
}

variable "container_port" {
  description = "Port the container listens on and the ALB target group forwards to."
  type        = number
  default     = 8080

  validation {
    condition     = var.container_port > 0 && var.container_port <= 65535
    error_message = "container_port must be between 1 and 65535."
  }
}

variable "container_command" {
  description = "Optional command override for the container entrypoint."
  type        = list(string)
  default     = []
}

variable "container_environment" {
  description = "Non-sensitive environment variables injected into the container. Use secret injection for credentials."
  type        = map(string)
  default     = {}
}

variable "cpu" {
  description = "Task-level CPU units (Fargate). Must form a valid pair with memory."
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.cpu)
    error_message = "cpu must be one of the Fargate values: 256, 512, 1024, 2048, 4096, 8192, 16384."
  }
}

variable "memory" {
  description = "Task-level memory in MiB (Fargate). Must form a valid pair with cpu."
  type        = number
  default     = 512
}

variable "cpu_architecture" {
  description = "CPU architecture for the Fargate runtime platform."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "container_health_check" {
  description = "Optional container-level health check. When command is empty, no container health check is configured."
  type = object({
    command      = optional(list(string), [])
    interval     = optional(number, 30)
    timeout      = optional(number, 5)
    retries      = optional(number, 3)
    start_period = optional(number, 10)
  })
  default = {}
}

# --- IAM ----------------------------------------------------------------------

variable "task_execution_role_arn" {
  description = "Existing task execution role ARN. When null, the module creates a least-privilege execution role."
  type        = string
  default     = null
}

variable "task_role_arn" {
  description = "Existing task role ARN for application permissions. When null, the module creates an empty task role."
  type        = string
  default     = null
}

# --- Logging ------------------------------------------------------------------

variable "log_retention_in_days" {
  description = "Retention for the container log group."
  type        = number
  default     = 30
}

variable "log_kms_key_arn" {
  description = "Optional KMS key ARN for encrypting the container log group."
  type        = string
  default     = null
}

# --- Load balancing -----------------------------------------------------------

variable "alb_listener_arn" {
  description = "ALB listener ARN to attach a forwarding rule to. When null, no listener rule is created and the caller wires the target group."
  type        = string
  default     = null
}

variable "alb_security_group_id" {
  description = "Security group of the ALB. When set, an ingress rule allows the ALB to reach the tasks on the container port."
  type        = string
  default     = null
}

variable "alb_arn_suffix" {
  description = "ARN suffix of the ALB (app/name/id). Required only when request-count target tracking is enabled."
  type        = string
  default     = null
}

variable "listener_rule_priority" {
  description = "Priority for the listener rule when alb_listener_arn is set."
  type        = number
  default     = 100

  validation {
    condition     = var.listener_rule_priority >= 1 && var.listener_rule_priority <= 50000
    error_message = "listener_rule_priority must be between 1 and 50000."
  }
}

variable "listener_host_headers" {
  description = "Host header values that route to this service. At least one host or path condition is required when a listener is set."
  type        = list(string)
  default     = []
}

variable "listener_path_patterns" {
  description = "Path patterns that route to this service. At least one host or path condition is required when a listener is set."
  type        = list(string)
  default     = []
}

variable "health_check_path" {
  description = "Target group health check path."
  type        = string
  default     = "/"
}

variable "health_check_matcher" {
  description = "HTTP codes considered healthy by the target group."
  type        = string
  default     = "200-399"
}

variable "deregistration_delay" {
  description = "Seconds the ALB waits before deregistering a draining target."
  type        = number
  default     = 30
}

# --- Service ------------------------------------------------------------------

variable "desired_count" {
  description = "Initial desired task count. Ongoing count is managed by autoscaling."
  type        = number
  default     = 2
}

variable "platform_version" {
  description = "Fargate platform version."
  type        = string
  default     = "LATEST"
}

variable "capacity_provider_strategy" {
  description = "Optional capacity provider strategy. When empty, the service uses the FARGATE launch type."
  type = list(object({
    capacity_provider = string
    base              = optional(number, 0)
    weight            = optional(number, 1)
  }))
  default = []

  validation {
    condition = length(setsubtract(
      [for s in var.capacity_provider_strategy : s.capacity_provider],
      ["FARGATE", "FARGATE_SPOT"],
    )) == 0
    error_message = "capacity_provider_strategy may only reference FARGATE and/or FARGATE_SPOT."
  }
}

variable "health_check_grace_period_seconds" {
  description = "Grace period before the service starts evaluating ALB health checks for new tasks."
  type        = number
  default     = 60
}

variable "enable_execute_command" {
  description = "Enable ECS Exec for interactive debugging of running tasks."
  type        = bool
  default     = true
}

variable "enable_deployment_circuit_breaker" {
  description = "Roll back automatically when a rolling deployment fails to stabilize."
  type        = bool
  default     = true
}

variable "deployment_minimum_healthy_percent" {
  description = "Lower bound on healthy tasks during a rolling deployment."
  type        = number
  default     = 100
}

variable "deployment_maximum_percent" {
  description = "Upper bound on running tasks during a rolling deployment."
  type        = number
  default     = 200
}

variable "additional_security_group_ids" {
  description = "Extra security groups attached to the tasks, in addition to the module-managed one."
  type        = list(string)
  default     = []
}

# --- Autoscaling --------------------------------------------------------------

variable "min_capacity" {
  description = "Minimum number of tasks maintained by autoscaling."
  type        = number
  default     = 2

  validation {
    condition     = var.min_capacity >= 1
    error_message = "min_capacity must be at least 1."
  }
}

variable "max_capacity" {
  description = "Maximum number of tasks autoscaling may run."
  type        = number
  default     = 10
}

variable "cpu_target_value" {
  description = "Target average CPU utilization percentage for target-tracking autoscaling."
  type        = number
  default     = 60

  validation {
    condition     = var.cpu_target_value > 0 && var.cpu_target_value <= 100
    error_message = "cpu_target_value must be between 1 and 100."
  }
}

variable "memory_target_value" {
  description = "Target average memory utilization percentage. When null, memory-based scaling is disabled."
  type        = number
  default     = null
}

variable "request_count_target" {
  description = "Target ALB requests per task for request-count scaling. When null, request-count scaling is disabled."
  type        = number
  default     = null
}

variable "scale_in_cooldown" {
  description = "Seconds to wait after a scale-in before another scale-in."
  type        = number
  default     = 300
}

variable "scale_out_cooldown" {
  description = "Seconds to wait after a scale-out before another scale-out."
  type        = number
  default     = 60
}

# --- Service Connect ----------------------------------------------------------

variable "service_connect_namespace" {
  description = "Cloud Map namespace ARN (or name) for ECS Service Connect. When null, Service Connect is disabled and the service is reachable only through its load balancer."
  type        = string
  default     = null
}

variable "service_connect_alias" {
  description = "DNS alias peers use to reach this service over Service Connect (for example checkout). When null, defaults to service_name."
  type        = string
  default     = null

  validation {
    condition     = var.service_connect_alias == null || can(regex("^[a-z][a-z0-9-]{0,62}$", coalesce(var.service_connect_alias, "x")))
    error_message = "service_connect_alias must be a lowercase hostname label starting with a letter, up to 63 characters."
  }
}

variable "service_connect_discovery_name" {
  description = "Discovery name registered in the namespace, unique within it. When null, defaults to service_name."
  type        = string
  default     = null
}

variable "service_connect_port_name" {
  description = "Name of the container port mapping exposed through Service Connect. When null, defaults to service_name."
  type        = string
  default     = null
}

variable "service_connect_dns_port" {
  description = "Port the Service Connect client alias listens on. When null, defaults to container_port."
  type        = number
  default     = null

  validation {
    condition     = var.service_connect_dns_port == null || (coalesce(var.service_connect_dns_port, 1) > 0 && coalesce(var.service_connect_dns_port, 1) <= 65535)
    error_message = "service_connect_dns_port must be between 1 and 65535."
  }
}

variable "service_connect_app_protocol" {
  description = "Application protocol advertised for the Service Connect port mapping: http, http2, or grpc."
  type        = string
  default     = "http"

  validation {
    condition     = contains(["http", "http2", "grpc"], var.service_connect_app_protocol)
    error_message = "service_connect_app_protocol must be one of: http, http2, grpc."
  }
}

variable "service_connect_peer_security_group_id" {
  description = "Optional security group of Service Connect peers allowed to reach the container port east-west. When set, an ingress rule references it instead of an open CIDR."
  type        = string
  default     = null
}

variable "enable_service_connect_logs" {
  description = "Stream Service Connect proxy logs to the container log group for east-west traffic observability."
  type        = bool
  default     = true
}

# --- Secret injection ---------------------------------------------------------

variable "container_secrets" {
  description = "Secrets injected into the container as environment variables at launch. value_from is the ARN of a Secrets Manager secret (optionally with a :json-key:: suffix) or an SSM Parameter Store parameter."
  type = list(object({
    name       = string
    value_from = string
  }))
  default = []
}

variable "secrets_manager_secret_arns" {
  description = "Secrets Manager secret ARNs the module-managed execution role may read to inject container secrets. List base secret ARNs (without any JSON-key suffix)."
  type        = list(string)
  default     = []
}

variable "ssm_parameter_arns" {
  description = "SSM Parameter Store parameter ARNs the module-managed execution role may read to inject container secrets."
  type        = list(string)
  default     = []
}

variable "secrets_kms_key_arns" {
  description = "KMS key ARNs used to decrypt SecureString SSM parameters or encrypted Secrets Manager secrets. Grants kms:Decrypt to the module-managed execution role."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags applied to all service resources."
  type        = map(string)
  default     = {}
}
