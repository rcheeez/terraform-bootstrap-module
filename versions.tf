terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
      # aws         = the region that holds the state bucket
      # aws.replica = a second region that holds the copy
      configuration_aliases = [aws.replica]
    }
  }
}
