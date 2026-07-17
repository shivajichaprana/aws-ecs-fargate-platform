# service-connect module

Creates the AWS Cloud Map namespace that ECS Service Connect uses for service
discovery. One namespace is shared across the platform: every service registers
into it and reaches its peers by a short alias (for example `http://checkout`)
over Service Connect's encrypted, proxy-managed mesh — no internal load balancer
and no externally resolvable DNS record.

## What it creates

- `aws_service_discovery_http_namespace` — an HTTP namespace for Service Connect.
  HTTP (rather than private DNS) is used because Service Connect resolves aliases
  through its sidecar proxy, keeping internal service names off any resolvable
  DNS zone.

## Usage

```hcl
module "service_connect" {
  source = "../../modules/service-connect"

  name_prefix = "ecs-platform"
  environment = "prod"
}

# Make the namespace the cluster default so services can omit it.
module "cluster" {
  source = "../../modules/ecs-cluster"

  name_prefix                   = "ecs-platform"
  environment                   = "prod"
  service_connect_namespace_arn = module.service_connect.namespace_arn
}

# Register a service into the namespace.
module "checkout" {
  source = "../../modules/service"

  name_prefix  = "ecs-platform"
  service_name = "checkout"
  environment  = "prod"

  cluster_arn  = module.cluster.cluster_arn
  cluster_name = module.cluster.cluster_name
  vpc_id       = var.vpc_id
  subnet_ids   = var.private_subnet_ids

  container_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/checkout:1.4.2"
  container_port  = 8080

  service_connect_namespace = module.service_connect.namespace_arn
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | `string` | — | Platform prefix shared by all services. |
| `environment` | `string` | `dev` | Environment identifier. |
| `namespace_name` | `string` | `null` | Namespace name; defaults to `<name_prefix>.<environment>.internal`. |
| `description` | `string` | `Service Connect namespace...` | Namespace description. |
| `tags` | `map(string)` | `{}` | Extra tags. |

## Outputs

| Name | Description |
|------|-------------|
| `namespace_arn` | Namespace ARN (pass to the cluster and service modules). |
| `namespace_id` | Namespace ID. |
| `namespace_name` | Namespace name. |
