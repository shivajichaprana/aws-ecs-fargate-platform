# Plan-time unit tests for the ECS Fargate service module.
#
# Every run plans against a mocked AWS provider, so the suite needs no
# credentials and touches no real infrastructure. Policy-document and region
# lookups are given deterministic mock values so rendered task definitions are
# stable and assertable. Assertions reference only values that are known at
# plan time (arguments, counts, and locals derived from input variables),
# never provider-computed attributes.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }
}

variables {
  name_prefix     = "ecs-platform"
  service_name    = "checkout"
  environment     = "dev"
  cluster_arn     = "arn:aws:ecs:us-east-1:123456789012:cluster/platform-dev"
  cluster_name    = "platform-dev"
  vpc_id          = "vpc-0123456789abcdef0"
  subnet_ids      = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  container_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/checkout:1.4.2"
}

# --- In-place rollout baseline ------------------------------------------------

run "rolling_service_defaults" {
  command = plan

  assert {
    condition     = length(aws_ecs_service.rolling) == 1 && length(aws_ecs_service.blue_green) == 0
    error_message = "The default rollout mode must create the in-place service only."
  }

  assert {
    condition     = aws_ecs_service.rolling[0].name == "ecs-platform-checkout-dev"
    error_message = "The service name must combine prefix, service, and environment."
  }

  assert {
    condition     = aws_ecs_service.rolling[0].launch_type == "FARGATE"
    error_message = "The service must use the FARGATE launch type when no capacity provider strategy is given."
  }

  assert {
    condition     = aws_ecs_service.rolling[0].deployment_circuit_breaker[0].enable == true && aws_ecs_service.rolling[0].deployment_circuit_breaker[0].rollback == true
    error_message = "The deployment circuit breaker must be enabled with rollback by default."
  }

  assert {
    condition     = length(aws_lb_target_group.green) == 0
    error_message = "No replacement target group may exist for in-place rollouts."
  }

  assert {
    condition     = aws_lb_target_group.this.name == "ecs-platform-checkout-dev"
    error_message = "In-place rollouts must keep the unsuffixed target group name."
  }

  assert {
    condition     = aws_lb_target_group.this.target_type == "ip" && aws_lb_target_group.this.port == 8080
    error_message = "The target group must use IP targets on the container port."
  }

  assert {
    condition     = aws_lb_target_group.this.health_check[0].path == "/"
    error_message = "The target group health check must default to the root path."
  }

  assert {
    condition     = aws_ecs_task_definition.this.family == "ecs-platform-checkout-dev"
    error_message = "The task definition family must match the service base name."
  }

  assert {
    condition     = tonumber(aws_ecs_task_definition.this.cpu) == 256 && tonumber(aws_ecs_task_definition.this.memory) == 512
    error_message = "The task must default to the smallest Fargate size."
  }

  assert {
    condition     = aws_ecs_task_definition.this.runtime_platform[0].cpu_architecture == "X86_64"
    error_message = "The runtime platform must default to X86_64."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].name == "checkout"
    error_message = "The container must be named after the service."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].image == var.container_image
    error_message = "The container must run the supplied image."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].essential == true
    error_message = "The single container must be essential."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].portMappings[0].containerPort == 8080
    error_message = "The port mapping must expose the default container port."
  }

  assert {
    condition     = !can(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].portMappings[0].name)
    error_message = "The port mapping must stay unnamed while Service Connect is disabled."
  }

  assert {
    condition     = !can(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].command)
    error_message = "No command override may be rendered when none is supplied."
  }

  assert {
    condition     = !can(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].healthCheck)
    error_message = "No container health check may be rendered when none is supplied."
  }

  assert {
    condition     = !can(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets)
    error_message = "No secrets block may be rendered when no secrets are supplied."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].logConfiguration.options["awslogs-group"] == "/ecs/ecs-platform-checkout-dev"
    error_message = "Container logs must stream to the module-managed log group."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].logConfiguration.options["awslogs-region"] == "us-east-1"
    error_message = "The awslogs driver must target the current region."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.name == "/ecs/ecs-platform-checkout-dev" && aws_cloudwatch_log_group.this.retention_in_days == 30
    error_message = "The log group must follow the naming convention with default retention."
  }

  assert {
    condition     = length(aws_iam_role.execution) == 1 && aws_iam_role.execution[0].name == "ecs-platform-checkout-dev-exec"
    error_message = "A module-managed execution role must be created when none is supplied."
  }

  assert {
    condition     = length(aws_iam_role.task) == 1 && aws_iam_role.task[0].name == "ecs-platform-checkout-dev-task"
    error_message = "A module-managed task role must be created when none is supplied."
  }

  assert {
    condition     = length(aws_iam_role_policy.exec) == 1
    error_message = "ECS Exec messaging permissions must be attached while exec is enabled."
  }

  assert {
    condition     = length(aws_iam_role_policy.secrets) == 0
    error_message = "No secrets-injection policy may be attached when no secret sources are supplied."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.from_alb) == 0 && length(aws_vpc_security_group_ingress_rule.from_mesh) == 0
    error_message = "No ingress rules may exist until an ALB or mesh peer security group is supplied."
  }

  assert {
    condition     = length(aws_lb_listener_rule.this) == 0
    error_message = "No listener rule may be created without a listener ARN."
  }

  assert {
    condition     = aws_appautoscaling_target.this.resource_id == "service/platform-dev/ecs-platform-checkout-dev"
    error_message = "The autoscaling target must address the service through the cluster name."
  }

  assert {
    condition     = aws_appautoscaling_target.this.min_capacity == 2 && aws_appautoscaling_target.this.max_capacity == 10
    error_message = "Autoscaling bounds must default to 2-10 tasks."
  }

  assert {
    condition     = aws_appautoscaling_policy.cpu.name == "ecs-platform-checkout-dev-cpu"
    error_message = "CPU target tracking must always be configured."
  }

  assert {
    condition     = length(aws_appautoscaling_policy.memory) == 0 && length(aws_appautoscaling_policy.requests) == 0
    error_message = "Memory and request-count scaling must stay disabled by default."
  }

  assert {
    condition     = output.service_name == "ecs-platform-checkout-dev" && output.container_name == "checkout"
    error_message = "Service and container name outputs must reflect the planned names."
  }

  assert {
    condition     = output.deployment_controller_type == "ECS" && output.green_target_group_name == null
    error_message = "In-place rollouts must report the ECS controller and no replacement group."
  }
}

run "rolling_service_with_alb_and_scaling" {
  command = plan

  variables {
    alb_security_group_id  = "sg-0123456789abcdef0"
    alb_listener_arn       = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/platform/0123456789abcdef/0123456789abcdef"
    listener_path_patterns = ["/checkout/*"]
    alb_arn_suffix         = "app/platform/0123456789abcdef"
    memory_target_value    = 70
    request_count_target   = 200
    container_environment  = { APP_ENV = "dev" }
    container_health_check = { command = ["CMD-SHELL", "curl -fsS http://localhost:8080/healthz || exit 1"] }
    capacity_provider_strategy = [
      { capacity_provider = "FARGATE", base = 1, weight = 1 },
      { capacity_provider = "FARGATE_SPOT", weight = 3 },
    ]
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.from_alb) == 1 && aws_vpc_security_group_ingress_rule.from_alb[0].from_port == 8080
    error_message = "The ALB ingress rule must open exactly the container port."
  }

  assert {
    condition     = length(aws_lb_listener_rule.this) == 1 && aws_lb_listener_rule.this[0].priority == 100
    error_message = "A listener rule must be created at the default priority when a listener is supplied."
  }

  assert {
    condition     = length(aws_ecs_service.rolling[0].capacity_provider_strategy) == 2
    error_message = "The service must adopt the supplied capacity provider strategy."
  }

  assert {
    condition     = one([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.value if e.name == "APP_ENV"]) == "dev"
    error_message = "Environment variables must be rendered into the container definition."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].healthCheck.command[0] == "CMD-SHELL"
    error_message = "The container health check must be rendered when a command is supplied."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].healthCheck.interval == 30
    error_message = "Health check timings must fall back to their defaults."
  }

  assert {
    condition     = length(aws_appautoscaling_policy.memory) == 1 && aws_appautoscaling_policy.memory[0].name == "ecs-platform-checkout-dev-memory"
    error_message = "Memory target tracking must be enabled when a target value is set."
  }

  assert {
    condition     = length(aws_appautoscaling_policy.requests) == 1 && aws_appautoscaling_policy.requests[0].name == "ecs-platform-checkout-dev-requests"
    error_message = "Request-count target tracking must be enabled when a target value is set."
  }
}

# --- Traffic-shifting rollout mode --------------------------------------------

run "blue_green_creates_paired_target_groups" {
  command = plan

  variables {
    deployment_controller_type = "CODE_DEPLOY"
  }

  assert {
    condition     = length(aws_ecs_service.rolling) == 0 && length(aws_ecs_service.blue_green) == 1
    error_message = "The CODE_DEPLOY mode must create the traffic-shifting service only."
  }

  assert {
    condition     = aws_ecs_service.blue_green[0].deployment_controller[0].type == "CODE_DEPLOY"
    error_message = "The service must hand rollouts to the external deployment controller."
  }

  assert {
    condition     = aws_lb_target_group.this.name == "ecs-platform-checkout-dev-blue"
    error_message = "The production target group must carry the blue suffix."
  }

  assert {
    condition     = length(aws_lb_target_group.green) == 1 && aws_lb_target_group.green[0].name == "ecs-platform-checkout-dev-green"
    error_message = "A replacement target group with the green suffix must be created."
  }

  assert {
    condition     = output.green_target_group_name == "ecs-platform-checkout-dev-green"
    error_message = "The replacement target group name must be exported for the deployment module."
  }

  assert {
    condition     = length(aws_lb_listener_rule.this) == 0
    error_message = "No listener rule may be created in traffic-shifting mode."
  }
}

run "long_names_stay_within_target_group_limit" {
  command = plan

  variables {
    service_name               = "recommendation-eng"
    deployment_controller_type = "CODE_DEPLOY"
  }

  assert {
    condition     = length(aws_lb_target_group.this.name) <= 32 && length(aws_lb_target_group.green[0].name) <= 32
    error_message = "Both target group names must stay within the 32-character limit."
  }

  assert {
    condition     = aws_lb_target_group.this.name != aws_lb_target_group.green[0].name
    error_message = "The paired target group names must never collide after truncation."
  }

  assert {
    condition     = endswith(aws_lb_target_group.this.name, "-blue") && endswith(aws_lb_target_group.green[0].name, "-green")
    error_message = "The paired target groups must keep their role suffixes after truncation."
  }
}

# --- Service Connect and secret injection -------------------------------------

run "service_connect_and_secret_injection" {
  command = plan

  variables {
    service_connect_namespace              = "arn:aws:servicediscovery:us-east-1:123456789012:namespace/ns-0a1b2c3d4e5f6a7b8"
    service_connect_peer_security_group_id = "sg-0fedcba9876543210"
    container_secrets = [
      { name = "DATABASE_PASSWORD", value_from = "arn:aws:secretsmanager:us-east-1:123456789012:secret:platform/checkout/db-AbC123" },
    ]
    secrets_manager_secret_arns = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:platform/checkout/db-AbC123"]
    secrets_kms_key_arns        = ["arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"]
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].portMappings[0].name == "checkout"
    error_message = "The port mapping must be named after the service for Service Connect."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].portMappings[0].appProtocol == "http"
    error_message = "The port mapping must advertise the default http application protocol."
  }

  assert {
    condition     = length(aws_ecs_service.rolling[0].service_connect_configuration) == 1 && aws_ecs_service.rolling[0].service_connect_configuration[0].enabled == true
    error_message = "Service Connect must be enabled when a namespace is supplied."
  }

  assert {
    condition     = aws_ecs_service.rolling[0].service_connect_configuration[0].namespace == var.service_connect_namespace
    error_message = "The service must register into the supplied namespace."
  }

  assert {
    condition     = aws_ecs_service.rolling[0].service_connect_configuration[0].service[0].port_name == "checkout"
    error_message = "The Service Connect port name must default to the service name."
  }

  assert {
    condition     = aws_ecs_service.rolling[0].service_connect_configuration[0].service[0].client_alias[0].dns_name == "checkout" && aws_ecs_service.rolling[0].service_connect_configuration[0].service[0].client_alias[0].port == 8080
    error_message = "The client alias must default to the service name on the container port."
  }

  assert {
    condition     = length(aws_ecs_service.rolling[0].service_connect_configuration[0].log_configuration) == 1
    error_message = "Service Connect proxy logs must stream to the service log group by default."
  }

  assert {
    condition     = one([for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.valueFrom if s.name == "DATABASE_PASSWORD"]) == "arn:aws:secretsmanager:us-east-1:123456789012:secret:platform/checkout/db-AbC123"
    error_message = "Container secrets must be rendered as valueFrom references, never literal values."
  }

  assert {
    condition     = length(aws_iam_role_policy.secrets) == 1
    error_message = "A scoped secrets-read policy must be attached to the module-managed execution role."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.from_mesh) == 1 && aws_vpc_security_group_ingress_rule.from_mesh[0].from_port == 8080
    error_message = "Mesh peers must be allowed to reach exactly the container port."
  }
}

# --- Input and precondition guardrails ----------------------------------------

run "rejects_invalid_service_name" {
  command = plan

  variables {
    service_name = "Checkout"
  }

  expect_failures = [var.service_name]
}

run "rejects_invalid_environment" {
  command = plan

  variables {
    environment = "qa"
  }

  expect_failures = [var.environment]
}

run "rejects_invalid_cpu_value" {
  command = plan

  variables {
    cpu = 300
  }

  expect_failures = [var.cpu]
}

run "rejects_invalid_deployment_controller" {
  command = plan

  variables {
    deployment_controller_type = "EXTERNAL"
  }

  expect_failures = [var.deployment_controller_type]
}

run "rejects_invalid_fargate_memory_pair" {
  command = plan

  variables {
    cpu    = 256
    memory = 4096
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "rejects_max_capacity_below_min" {
  command = plan

  variables {
    min_capacity = 4
    max_capacity = 2
  }

  expect_failures = [aws_appautoscaling_target.this]
}
