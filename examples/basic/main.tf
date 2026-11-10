# Creates the state storage once per AWS account.
#   terraform init
#   terraform apply -var="bucket_name=tfstate-123456789012"
# Then follow "Move this stack's own state into the bucket" in the README.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

variable "bucket_name" {
  description = "Unique name for the state bucket, for example tfstate-<account-id>."
  type        = string
}

provider "aws" {
  region = "us-east-1" # where the state bucket lives
}

provider "aws" {
  alias  = "replica"
  region = "us-west-2" # where the copy lives
}

module "state" {
  source = "../.."

  bucket_name = var.bucket_name
  tags = {
    purpose = "terraform-state"
  }

  providers = {
    aws         = aws
    aws.replica = aws.replica
  }
}

output "backend_config" {
  value = module.state.backend_config
}
