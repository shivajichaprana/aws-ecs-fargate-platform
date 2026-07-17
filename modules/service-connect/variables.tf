variable "name_prefix" {
  description = "Platform prefix shared by all services (for example ecs-platform)."
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

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "namespace_name" {
  description = "Name of the Service Connect (Cloud Map) namespace. When null, defaults to <name_prefix>.<environment>.internal."
  type        = string
  default     = null
}

variable "description" {
  description = "Description applied to the Service Connect namespace."
  type        = string
  default     = "Service Connect namespace for ECS Fargate services."
}

variable "tags" {
  description = "Additional tags applied to the namespace."
  type        = map(string)
  default     = {}
}
