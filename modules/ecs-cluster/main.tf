# ECS cluster foundation.
#
# Provides a Fargate-only cluster wired to the FARGATE and FARGATE_SPOT capacity
# providers, Container Insights for metrics, and an encrypted audit trail for
# ECS Exec sessions. No EC2 capacity is managed here — services run serverless
# on Fargate.

data "aws_caller_identity" "current" {}

locals {
  cluster_name = "${var.name_prefix}-${var.environment}"

  # Use the caller-supplied key when provided, otherwise the module-managed key.
  exec_kms_key_arn = var.enable_execute_command_logging ? (
    var.kms_key_arn != null ? var.kms_key_arn : aws_kms_key.exec[0].arn
  ) : null

  base_tags = merge(
    {
      Name        = local.cluster_name
      Environment = var.environment
    },
    var.tags,
  )
}

# --- ECS Exec session encryption key (module-managed when not supplied) -------

resource "aws_kms_key" "exec" {
  count = var.enable_execute_command_logging && var.kms_key_arn == null ? 1 : 0

  description             = "ECS Exec session encryption for ${local.cluster_name}"
  deletion_window_in_days = 14
  enable_key_rotation     = true

  tags = local.base_tags
}

resource "aws_kms_alias" "exec" {
  count = var.enable_execute_command_logging && var.kms_key_arn == null ? 1 : 0

  name          = "alias/${local.cluster_name}-ecs-exec"
  target_key_id = aws_kms_key.exec[0].key_id
}

# --- ECS Exec audit log group -------------------------------------------------

resource "aws_cloudwatch_log_group" "exec" {
  count = var.enable_execute_command_logging ? 1 : 0

  name              = "/ecs/${local.cluster_name}/exec"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = local.exec_kms_key_arn

  tags = local.base_tags
}

# --- Cluster ------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = local.cluster_name

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  # Encrypt and (optionally) record ECS Exec sessions so interactive access to
  # running tasks is auditable.
  dynamic "configuration" {
    for_each = var.enable_execute_command_logging ? [1] : []
    content {
      execute_command_configuration {
        kms_key_id = local.exec_kms_key_arn
        logging    = "OVERRIDE"

        log_configuration {
          cloud_watch_encryption_enabled = true
          cloud_watch_log_group_name     = aws_cloudwatch_log_group.exec[0].name
        }
      }
    }
  }

  tags = local.base_tags
}

# --- Capacity providers -------------------------------------------------------

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = var.capacity_providers

  dynamic "default_capacity_provider_strategy" {
    for_each = var.default_capacity_provider_strategy
    content {
      capacity_provider = default_capacity_provider_strategy.value.capacity_provider
      base              = default_capacity_provider_strategy.value.base
      weight            = default_capacity_provider_strategy.value.weight
    }
  }

  lifecycle {
    precondition {
      condition = length(setsubtract(
        [for s in var.default_capacity_provider_strategy : s.capacity_provider],
        var.capacity_providers,
      )) == 0
      error_message = "Every provider in default_capacity_provider_strategy must also appear in capacity_providers."
    }
  }
}
