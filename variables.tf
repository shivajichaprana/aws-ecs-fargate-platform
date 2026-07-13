variable "region" {
  description = "AWS region to deploy the platform into."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to the names of all platform resources."
  type        = string
  default     = "ecs-platform"

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

variable "default_tags" {
  description = "Tags applied to every resource via the provider default_tags block."
  type        = map(string)
  default = {
    Platform  = "ecs-fargate"
    ManagedBy = "terraform"
  }
}
