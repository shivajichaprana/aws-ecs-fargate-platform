# Default provider. Region and default tags are driven by input variables so
# the same configuration can be reused across environments and accounts.
provider "aws" {
  region = var.region

  default_tags {
    tags = var.default_tags
  }
}
