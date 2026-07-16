# aws-ecs-fargate-platform

A production-oriented Amazon ECS on AWS Fargate platform, delivered as reusable
Terraform. It provides a hardened cluster foundation and composable modules for
running containerized services with autoscaling, private service-to-service
networking, secret injection, and safe progressive rollouts.

## Capabilities

- **Cluster foundation** — an ECS cluster wired to the `FARGATE` and
  `FARGATE_SPOT` capacity providers with a tunable default strategy, plus
  Container Insights for cluster and task metrics.
- **Reusable service module** — task definition, service, ALB target group, and
  target-tracking autoscaling behind a small input surface.
- **Private service networking** — ECS Service Connect for service discovery and
  encrypted service-to-service traffic without exposing internal endpoints.
- **Configuration and secrets** — Secrets Manager and SSM Parameter Store values
  injected into task definitions at launch rather than baked into images.
- **Safe rollouts** — CodeDeploy blue/green deployments with a deployment circuit
  breaker and automatic rollback on failed health checks.

## Repository layout

| Path | Purpose |
|------|---------|
| `versions.tf` | Terraform and provider version constraints |
| `providers.tf` | AWS provider configuration and default tags |
| `variables.tf` | Root input variables (region, naming, environment, tags) |
| `modules/ecs-cluster/` | ECS cluster with Fargate capacity providers and Container Insights |
| `modules/service/` | Reusable service: task definition, ALB target group, and target-tracking autoscaling |

Additional modules (service, networking, and deployment) are layered on top of
the cluster foundation.

## Requirements

- Terraform `>= 1.6.0`
- AWS provider `>= 5.40.0, < 6.0.0`
- An AWS account with permissions to manage ECS, IAM, CloudWatch, ELB, and
  related services

## Usage

```hcl
module "cluster" {
  source = "./modules/ecs-cluster"

  name_prefix = "ecs-platform"
  environment = "prod"

  # Bias steady-state capacity toward Spot for cost, keep a small on-demand base.
  default_capacity_provider_strategy = [
    { capacity_provider = "FARGATE",      base = 1, weight = 1 },
    { capacity_provider = "FARGATE_SPOT", base = 0, weight = 4 },
  ]
}
```

All example account identifiers in this repository use the reserved placeholder
`123456789012`. Replace placeholders such as `<your-github-org>` and
`<your-bucket-name>` with values for your own environment before applying.

## Contributing

Open a Discussion in the repository or comment on the PR. Security issues should
be reported via a GitHub Security Advisory rather than a public issue.

## License

Released under the [MIT License](LICENSE).
