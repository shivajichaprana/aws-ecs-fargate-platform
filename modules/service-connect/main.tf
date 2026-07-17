# Service Connect namespace.
#
# Creates the AWS Cloud Map namespace that ECS Service Connect uses to register
# and discover services. A single namespace is shared by every service on the
# platform, so services reach one another by a stable, short alias over an
# encrypted, proxy-managed mesh instead of a load balancer or a hardcoded
# endpoint. An HTTP namespace is used because Service Connect resolves aliases
# through its own sidecar rather than public DNS, which keeps internal traffic
# off any externally resolvable record.

locals {
  # Default to a private, non-resolvable name scoped to the platform and
  # environment so two environments never collide in the same account.
  namespace_name = coalesce(var.namespace_name, "${var.name_prefix}.${var.environment}.internal")

  base_tags = merge(
    {
      Name        = local.namespace_name
      Environment = var.environment
    },
    var.tags,
  )
}

resource "aws_service_discovery_http_namespace" "this" {
  name        = local.namespace_name
  description = var.description

  tags = local.base_tags
}
