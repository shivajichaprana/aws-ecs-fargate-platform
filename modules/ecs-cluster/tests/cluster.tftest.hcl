# Plan-time unit tests for the ECS cluster module.
#
# Every run plans against a mocked AWS provider, so the suite needs no
# credentials and touches no real infrastructure. Assertions reference only
# values that are known at plan time (arguments, counts, and locals derived
# from input variables), never provider-computed attributes.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

variables {
  name_prefix = "platform"
  environment = "dev"
}

# --- Baseline behaviour -------------------------------------------------------

run "cluster_defaults" {
  command = plan

  assert {
    condition     = aws_ecs_cluster.this.name == "platform-dev"
    error_message = "Cluster name must be the name prefix joined with the environment."
  }

  assert {
    condition     = one([for s in aws_ecs_cluster.this.setting : s.value if s.name == "containerInsights"]) == "enabled"
    error_message = "Container Insights must default to enabled."
  }

  assert {
    condition     = length(aws_ecs_cluster_capacity_providers.this.capacity_providers) == 2
    error_message = "Both Fargate capacity providers must be associated by default."
  }

  assert {
    condition     = contains(aws_ecs_cluster_capacity_providers.this.capacity_providers, "FARGATE") && contains(aws_ecs_cluster_capacity_providers.this.capacity_providers, "FARGATE_SPOT")
    error_message = "Default capacity providers must be FARGATE and FARGATE_SPOT."
  }

  assert {
    condition     = one([for s in aws_ecs_cluster_capacity_providers.this.default_capacity_provider_strategy : s.base if s.capacity_provider == "FARGATE"]) == 1
    error_message = "The default strategy must keep at least one task on on-demand FARGATE."
  }

  assert {
    condition     = length(aws_kms_key.exec) == 1 && length(aws_kms_alias.exec) == 1
    error_message = "A module-managed KMS key and alias must be created when no key is supplied."
  }

  assert {
    condition     = aws_kms_alias.exec[0].name == "alias/platform-dev-ecs-exec"
    error_message = "The KMS alias must be scoped to the cluster name."
  }

  assert {
    condition     = aws_cloudwatch_log_group.exec[0].name == "/ecs/platform-dev/exec"
    error_message = "The ECS Exec audit log group must follow the /ecs/<cluster>/exec convention."
  }

  assert {
    condition     = aws_cloudwatch_log_group.exec[0].retention_in_days == 90
    error_message = "The ECS Exec audit log group must default to 90-day retention."
  }

  assert {
    condition     = length(aws_ecs_cluster.this.service_connect_defaults) == 0
    error_message = "No Service Connect cluster default may be set unless a namespace is supplied."
  }

  assert {
    condition     = aws_ecs_cluster.this.tags["Name"] == "platform-dev" && aws_ecs_cluster.this.tags["Environment"] == "dev"
    error_message = "Base tags must carry the cluster name and environment."
  }
}

run "custom_capacity_configuration" {
  command = plan

  variables {
    container_insights = "disabled"
    capacity_providers = ["FARGATE"]
    default_capacity_provider_strategy = [
      { capacity_provider = "FARGATE" },
    ]
  }

  assert {
    condition     = one([for s in aws_ecs_cluster.this.setting : s.value if s.name == "containerInsights"]) == "disabled"
    error_message = "Container Insights must be configurable to disabled."
  }

  assert {
    condition     = length(aws_ecs_cluster_capacity_providers.this.capacity_providers) == 1
    error_message = "Only the requested capacity providers may be associated."
  }

  assert {
    condition     = one([for s in aws_ecs_cluster_capacity_providers.this.default_capacity_provider_strategy : s.weight if s.capacity_provider == "FARGATE"]) == 1
    error_message = "Strategy entries must fall back to the default weight of 1."
  }
}

# --- ECS Exec encryption and audit logging ------------------------------------

run "caller_supplied_kms_key" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = length(aws_kms_key.exec) == 0 && length(aws_kms_alias.exec) == 0
    error_message = "No module-managed key may be created when the caller supplies one."
  }

  assert {
    condition     = aws_cloudwatch_log_group.exec[0].kms_key_id == var.kms_key_arn
    error_message = "The audit log group must be encrypted with the caller-supplied key."
  }

  assert {
    condition     = output.exec_kms_key_arn == var.kms_key_arn
    error_message = "The exec_kms_key_arn output must surface the caller-supplied key."
  }
}

run "exec_logging_disabled" {
  command = plan

  variables {
    enable_execute_command_logging = false
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.exec) == 0 && length(aws_kms_key.exec) == 0
    error_message = "No audit log group or KMS key may be created when exec logging is disabled."
  }

  assert {
    condition     = length(aws_ecs_cluster.this.configuration) == 0
    error_message = "The cluster must carry no execute-command configuration when exec logging is disabled."
  }

  assert {
    condition     = output.exec_log_group_name == null && output.exec_kms_key_arn == null
    error_message = "Exec outputs must be null when exec logging is disabled."
  }
}

# --- Service Connect cluster default ------------------------------------------

run "service_connect_cluster_default" {
  command = plan

  variables {
    service_connect_namespace_arn = "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-0a1b2c3d4e5f6a7b8"
  }

  assert {
    condition     = length(aws_ecs_cluster.this.service_connect_defaults) == 1
    error_message = "A Service Connect cluster default must be set when a namespace is supplied."
  }

  assert {
    condition     = aws_ecs_cluster.this.service_connect_defaults[0].namespace == var.service_connect_namespace_arn
    error_message = "The cluster default must reference the supplied namespace ARN."
  }
}

# --- Input and precondition guardrails ----------------------------------------

run "rejects_invalid_name_prefix" {
  command = plan

  variables {
    name_prefix = "Platform"
  }

  expect_failures = [var.name_prefix]
}

run "rejects_invalid_container_insights" {
  command = plan

  variables {
    container_insights = "detailed"
  }

  expect_failures = [var.container_insights]
}

run "rejects_unknown_capacity_provider" {
  command = plan

  variables {
    capacity_providers = ["FARGATE", "EC2"]
  }

  expect_failures = [var.capacity_providers]
}

run "rejects_strategy_outside_capacity_providers" {
  command = plan

  variables {
    capacity_providers = ["FARGATE"]
    default_capacity_provider_strategy = [
      { capacity_provider = "FARGATE_SPOT" },
    ]
  }

  expect_failures = [aws_ecs_cluster_capacity_providers.this]
}
