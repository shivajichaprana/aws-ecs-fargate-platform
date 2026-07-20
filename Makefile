# Local entry points for the ECS Fargate platform. These mirror the CI
# pipeline, so a clean `make validate test lint checkov` locally corresponds
# to a green pipeline run.
#
# Plan/apply/destroy operate on the root configuration and require AWS
# credentials for the target account; everything else runs offline.

TERRAFORM ?= terraform
TFLINT    ?= tflint
CHECKOV   ?= checkov

# Root plus every module is validated; only modules with a tests/ directory
# are exercised by `terraform test`.
MODULE_DIRS := $(wildcard modules/*)
TF_DIRS     := . $(MODULE_DIRS)
TEST_DIRS   := $(patsubst %/tests,%,$(wildcard modules/*/tests))

# Checkov skips are documented policy decisions, kept identical to CI:
#   CKV_AWS_338 - log retention is caller-configurable by design
#   CKV2_AWS_64 - default key policy on the ECS Exec KMS key is deliberate
#   CKV_AWS_378 - TLS terminates at the listener; target traffic stays in-VPC
CHECKOV_SKIPS := CKV_AWS_338,CKV2_AWS_64,CKV_AWS_378

.DEFAULT_GOAL := help

.PHONY: help init fmt fmt-check validate plan apply destroy test lint checkov clean

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: ## Initialize root and all modules (no backend)
	@for dir in $(TF_DIRS); do \
		echo "==> init $$dir"; \
		$(TERRAFORM) -chdir=$$dir init -backend=false -input=false >/dev/null || exit 1; \
	done

fmt: ## Rewrite all Terraform files to canonical format
	$(TERRAFORM) fmt -recursive

fmt-check: ## Fail if any file is not canonically formatted (CI parity)
	$(TERRAFORM) fmt -check -diff -recursive

validate: init ## Run terraform validate across root and every module
	@for dir in $(TF_DIRS); do \
		echo "==> validate $$dir"; \
		$(TERRAFORM) -chdir=$$dir validate || exit 1; \
	done

plan: init ## Plan the root configuration (requires AWS credentials)
	$(TERRAFORM) plan -input=false

apply: init ## Apply the root configuration (requires AWS credentials)
	$(TERRAFORM) apply -input=false

destroy: ## Destroy the root configuration (requires AWS credentials)
	$(TERRAFORM) destroy -input=false

test: ## Run native terraform test suites (mocked provider, no credentials)
	@for dir in $(TEST_DIRS); do \
		echo "==> test $$dir"; \
		(cd $$dir && $(TERRAFORM) init -backend=false -input=false >/dev/null && $(TERRAFORM) test) || exit 1; \
	done

lint: ## Run tflint recursively, failing on errors only (CI parity)
	$(TFLINT) --recursive --minimum-failure-severity=error --format=compact

checkov: ## Run checkov static security analysis with documented skips
	$(CHECKOV) --directory . --framework terraform --skip-download \
		--quiet --compact --skip-check $(CHECKOV_SKIPS)

clean: ## Remove local Terraform working directories and plan files
	find . -type d -name ".terraform" -prune -exec rm -rf {} +
	find . -type f \( -name "*.tfplan" -o -name ".terraform.lock.hcl" \) -delete
