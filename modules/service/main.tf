# Reusable ECS Fargate service.
#
# Packages the resources needed to run one containerized service on an existing
# Fargate cluster: a CloudWatch-logged task definition, an ECS service wired to
# an ALB target group, a task security group, least-privilege IAM roles, and
# target-tracking autoscaling on CPU, memory, and ALB request count. The service
# can register into a Service Connect namespace for private service-to-service
# discovery and inject configuration from Secrets Manager and SSM Parameter Store
# at launch. The input surface is deliberately small so a service can be onboarded
# by supplying an image, a port, and the cluster and network it belongs to.

data "aws_region" "current" {}

locals {
  base_name      = "${var.name_prefix}-${var.service_name}-${var.environment}"
  container_name = var.service_name

  # Target group names are capped at 32 characters and must not start or end
  # with a hyphen.
  target_group_name = trim(substr(local.base_name, 0, 32), "-")

  create_execution_role = var.task_execution_role_arn == null
  create_task_role      = var.task_role_arn == null

  execution_role_arn = local.create_execution_role ? aws_iam_role.execution[0].arn : var.task_execution_role_arn
  task_role_arn      = local.create_task_role ? aws_iam_role.task[0].arn : var.task_role_arn

  create_listener_rule = var.alb_listener_arn != null

  # Service Connect is enabled whenever a namespace is supplied. The port mapping
  # is named so the Service Connect service can reference it, and the client alias
  # defaults to the service name and container port so callers reach the service
  # at http://<service_name>:<port> without a load balancer or resolvable DNS.
  enable_service_connect         = var.service_connect_namespace != null
  service_connect_port_name      = coalesce(var.service_connect_port_name, var.service_name)
  service_connect_discovery_name = coalesce(var.service_connect_discovery_name, var.service_name)
  service_connect_alias          = coalesce(var.service_connect_alias, var.service_name)
  service_connect_dns_port       = coalesce(var.service_connect_dns_port, var.container_port)

  # A scoped read policy is attached to a module-managed execution role only when
  # at least one secret source ARN is supplied. The three source lists map to the
  # services the execution role may need to reach to resolve injected secrets:
  # Secrets Manager, SSM Parameter Store, and the KMS key that decrypts them.
  create_secrets_policy = local.create_execution_role && (
    length(var.secrets_manager_secret_arns) > 0 ||
    length(var.ssm_parameter_arns) > 0 ||
    length(var.secrets_kms_key_arns) > 0
  )

  container_health_check = length(var.container_health_check.command) > 0 ? {
    command     = var.container_health_check.command
    interval    = var.container_health_check.interval
    timeout     = var.container_health_check.timeout
    retries     = var.container_health_check.retries
    startPeriod = var.container_health_check.start_period
  } : null

  # Port mapping. The Service Connect name and application protocol are added only
  # when a namespace is configured, so the rendered task definition is unchanged
  # for services that do not use Service Connect.
  port_mapping = merge(
    {
      containerPort = var.container_port
      protocol      = "tcp"
    },
    local.enable_service_connect ? {
      name        = local.service_connect_port_name
      appProtocol = var.service_connect_app_protocol
    } : {},
  )

  # Single-container definition. Optional keys (command, healthCheck, secrets) are
  # merged in only when set so the rendered JSON never carries null fields, which
  # keeps the task definition stable across plans. Non-sensitive configuration is
  # passed as environment variables; credentials are injected as secrets sourced
  # from Secrets Manager or SSM Parameter Store, never baked into the image.
  container_definition = merge(
    {
      name      = local.container_name
      image     = var.container_image
      essential = true

      portMappings = [local.port_mapping]

      environment = [
        for key, value in var.container_environment : {
          name  = key
          value = value
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = var.service_name
        }
      }
    },
    length(var.container_command) > 0 ? { command = var.container_command } : {},
    local.container_health_check != null ? { healthCheck = local.container_health_check } : {},
    length(var.container_secrets) > 0 ? {
      secrets = [
        for s in var.container_secrets : {
          name      = s.name
          valueFrom = s.value_from
        }
      ]
    } : {},
  )

  # Valid Fargate memory values for each CPU size, used to reject invalid pairs
  # before the API rejects the deployment.
  fargate_cpu_memory = {
    256   = [512, 1024, 2048]
    512   = range(1024, 4097, 1024)
    1024  = range(2048, 8193, 1024)
    2048  = range(4096, 16385, 1024)
    4096  = range(8192, 30721, 1024)
    8192  = range(16384, 61441, 4096)
    16384 = range(32768, 122881, 8192)
  }

  base_tags = merge(
    {
      Name        = local.base_name
      Environment = var.environment
      Service     = var.service_name
    },
    var.tags,
  )
}

# --- Logging ------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.base_name}"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = var.log_kms_key_arn

  tags = local.base_tags
}

# --- IAM ----------------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: used by the ECS agent to pull images and write logs.
resource "aws_iam_role" "execution" {
  count = local.create_execution_role ? 1 : 0

  name                 = "${local.base_name}-exec"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = 3600

  tags = local.base_tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  count = local.create_execution_role ? 1 : 0

  role       = aws_iam_role.execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Secret injection: allow the execution role to read only the specific Secrets
# Manager secrets and SSM parameters wired into the task definition, and to
# decrypt them with the supplied KMS keys. Attached only when the module manages
# the execution role and at least one source ARN is supplied.
data "aws_iam_policy_document" "secrets" {
  count = local.create_secrets_policy ? 1 : 0

  dynamic "statement" {
    for_each = length(var.secrets_manager_secret_arns) > 0 ? [1] : []
    content {
      sid       = "ReadSecretsManager"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.secrets_manager_secret_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.ssm_parameter_arns) > 0 ? [1] : []
    content {
      sid       = "ReadSsmParameters"
      effect    = "Allow"
      actions   = ["ssm:GetParameter", "ssm:GetParameters"]
      resources = var.ssm_parameter_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.secrets_kms_key_arns) > 0 ? [1] : []
    content {
      sid       = "DecryptSecrets"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = var.secrets_kms_key_arns
    }
  }
}

resource "aws_iam_role_policy" "secrets" {
  count = local.create_secrets_policy ? 1 : 0

  name   = "secrets-injection"
  role   = aws_iam_role.execution[0].id
  policy = data.aws_iam_policy_document.secrets[0].json
}

# Task role: assumed by the application. Starts empty; application permissions
# are attached by the caller.
resource "aws_iam_role" "task" {
  count = local.create_task_role ? 1 : 0

  name                 = "${local.base_name}-task"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = 3600

  tags = local.base_tags
}

# ECS Exec needs SSM messaging permissions on the task role to open sessions.
data "aws_iam_policy_document" "exec" {
  count = local.create_task_role && var.enable_execute_command ? 1 : 0

  statement {
    sid    = "AllowExecuteCommandChannel"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "exec" {
  count = local.create_task_role && var.enable_execute_command ? 1 : 0

  name   = "ecs-exec"
  role   = aws_iam_role.task[0].id
  policy = data.aws_iam_policy_document.exec[0].json
}

# --- Task security group ------------------------------------------------------

resource "aws_security_group" "task" {
  name        = "${local.base_name}-task"
  description = "Task ENI security group for ${local.base_name}."
  vpc_id      = var.vpc_id

  tags = local.base_tags

  lifecycle {
    create_before_destroy = true
  }
}

# Allow the ALB to reach the container port. Created only when an ALB security
# group is supplied so the reference is a security group, never an open CIDR.
resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  count = var.alb_security_group_id != null ? 1 : 0

  security_group_id            = aws_security_group.task.id
  description                  = "Allow ALB to reach the container port."
  referenced_security_group_id = var.alb_security_group_id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"

  tags = local.base_tags
}

# Allow peer services in the same Service Connect namespace to reach the
# container port. Created only when Service Connect is enabled and a peer
# security group is supplied, keeping east-west access scoped to a security
# group rather than an open CIDR.
resource "aws_vpc_security_group_ingress_rule" "from_mesh" {
  count = local.enable_service_connect && var.service_connect_peer_security_group_id != null ? 1 : 0

  security_group_id            = aws_security_group.task.id
  description                  = "Allow Service Connect peers to reach the container port."
  referenced_security_group_id = var.service_connect_peer_security_group_id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"

  tags = local.base_tags
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.task.id
  description       = "Allow all outbound traffic."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = local.base_tags
}

# --- Target group -------------------------------------------------------------

resource "aws_lb_target_group" "this" {
  name        = local.target_group_name
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  deregistration_delay = var.deregistration_delay

  health_check {
    enabled             = true
    path                = var.health_check_path
    matcher             = var.health_check_matcher
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }

  tags = local.base_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "this" {
  count = local.create_listener_rule ? 1 : 0

  listener_arn = var.alb_listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  dynamic "condition" {
    for_each = length(var.listener_host_headers) > 0 ? [1] : []
    content {
      host_header {
        values = var.listener_host_headers
      }
    }
  }

  dynamic "condition" {
    for_each = length(var.listener_path_patterns) > 0 ? [1] : []
    content {
      path_pattern {
        values = var.listener_path_patterns
      }
    }
  }

  tags = local.base_tags

  lifecycle {
    precondition {
      condition     = length(var.listener_host_headers) > 0 || length(var.listener_path_patterns) > 0
      error_message = "When alb_listener_arn is set, provide at least one listener_host_headers or listener_path_patterns value."
    }
  }
}

# --- Task definition ----------------------------------------------------------

resource "aws_ecs_task_definition" "this" {
  family                   = local.base_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = local.execution_role_arn
  task_role_arn            = local.task_role_arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([local.container_definition])

  tags = local.base_tags

  lifecycle {
    precondition {
      condition     = contains(lookup(local.fargate_cpu_memory, var.cpu, []), var.memory)
      error_message = "memory is not a valid Fargate value for the selected cpu. See the Fargate task size matrix."
    }
    precondition {
      condition     = length(var.container_secrets) == 0 || !local.create_execution_role || (length(var.secrets_manager_secret_arns) + length(var.ssm_parameter_arns)) > 0
      error_message = "When container_secrets are set and the module manages the execution role, provide secrets_manager_secret_arns and/or ssm_parameter_arns so the execution role can read them."
    }
  }
}

# --- Service ------------------------------------------------------------------

resource "aws_ecs_service" "this" {
  name             = local.base_name
  cluster          = var.cluster_arn
  task_definition  = aws_ecs_task_definition.this.arn
  desired_count    = var.desired_count
  platform_version = var.platform_version

  enable_execute_command            = var.enable_execute_command
  health_check_grace_period_seconds = var.health_check_grace_period_seconds

  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent

  deployment_circuit_breaker {
    enable   = var.enable_deployment_circuit_breaker
    rollback = var.enable_deployment_circuit_breaker
  }

  # Use the launch type unless the caller supplies a capacity provider strategy
  # (for example to bias steady-state capacity toward Spot).
  launch_type = length(var.capacity_provider_strategy) == 0 ? "FARGATE" : null

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      base              = capacity_provider_strategy.value.base
      weight            = capacity_provider_strategy.value.weight
    }
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = concat([aws_security_group.task.id], var.additional_security_group_ids)
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  # Register the service into the Service Connect namespace so peers can reach it
  # by its client alias over the encrypted mesh. Proxy logs are streamed to the
  # service log group by default for traffic observability.
  dynamic "service_connect_configuration" {
    for_each = local.enable_service_connect ? [1] : []
    content {
      enabled   = true
      namespace = var.service_connect_namespace

      service {
        port_name      = local.service_connect_port_name
        discovery_name = local.service_connect_discovery_name

        client_alias {
          port     = local.service_connect_dns_port
          dns_name = local.service_connect_alias
        }
      }

      dynamic "log_configuration" {
        for_each = var.enable_service_connect_logs ? [1] : []
        content {
          log_driver = "awslogs"
          options = {
            "awslogs-group"         = aws_cloudwatch_log_group.this.name
            "awslogs-region"        = data.aws_region.current.name
            "awslogs-stream-prefix" = "service-connect"
          }
        }
      }
    }
  }

  tags = local.base_tags

  # Autoscaling owns the running task count, so ignore drift on desired_count.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_target_group.this]
}

# --- Autoscaling --------------------------------------------------------------

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity

  lifecycle {
    precondition {
      condition     = var.max_capacity >= var.min_capacity
      error_message = "max_capacity must be greater than or equal to min_capacity."
    }
    precondition {
      condition     = var.request_count_target == null || var.alb_arn_suffix != null
      error_message = "alb_arn_suffix is required when request_count_target is set."
    }
  }
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.base_name}-cpu"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.cpu_target_value
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "memory" {
  count = var.memory_target_value != null ? 1 : 0

  name               = "${local.base_name}-memory"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = var.memory_target_value
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "requests" {
  count = var.request_count_target != null ? 1 : 0

  name               = "${local.base_name}-requests"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.alb_arn_suffix}/${aws_lb_target_group.this.arn_suffix}"
    }
    target_value       = var.request_count_target
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown
  }
}
