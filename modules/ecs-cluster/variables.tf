variable "name_prefix" {
  description = "Prefix applied to cluster resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with hyphens, 3-32 characters, and start with a letter."
  }
}

variable "environment" {
  description = "Environment identifier (for example dev, staging, or prod)."
  type        = string
  default     = "dev"
}

variable "container_insights" {
  description = "Container Insights mode for the cluster: enabled, enhanced, or disabled."
  type        = string
  default     = "enabled"

  validation {
    condition     = contains(["enabled", "enhanced", "disabled"], var.container_insights)
    error_message = "container_insights must be one of: enabled, enhanced, disabled."
  }
}

variable "capacity_providers" {
  description = "Fargate capacity providers to associate with the cluster."
  type        = list(string)
  default     = ["FARGATE", "FARGATE_SPOT"]

  validation {
    condition     = length(setsubtract(var.capacity_providers, ["FARGATE", "FARGATE_SPOT"])) == 0
    error_message = "capacity_providers may only contain FARGATE and/or FARGATE_SPOT."
  }
}

variable "default_capacity_provider_strategy" {
  description = "Default capacity provider strategy applied to services that do not declare their own."
  type = list(object({
    capacity_provider = string
    base              = optional(number, 0)
    weight            = optional(number, 1)
  }))
  default = [
    { capacity_provider = "FARGATE", base = 1, weight = 1 },
    { capacity_provider = "FARGATE_SPOT", base = 0, weight = 4 },
  ]
}

variable "enable_execute_command_logging" {
  description = "Send ECS Exec session activity to a dedicated, encrypted CloudWatch log group."
  type        = bool
  default     = true
}

variable "log_retention_in_days" {
  description = "Retention for the ECS Exec audit log group."
  type        = number
  default     = 90
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for ECS Exec session encryption. When null, a key is created and managed by this module."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags applied to cluster resources."
  type        = map(string)
  default     = {}
}
