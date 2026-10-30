# Same in every week. Each week is its own Terraform root with local state;
# later weeks read earlier weeks' outputs from ../weekNN/terraform.tfstate.
terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      workload   = "ai-platform-lab"
      costCenter = "learning"
      managedBy  = "terraform"
    }
  }
}

variable "region" {
  description = "Canada Central. Change only if you understand the data residency lesson in week 3."
  type        = string
  default     = "ca-central-1"
}

variable "prefix" {
  description = "Short name used in every resource name."
  type        = string
  default     = "aiplat"
}
