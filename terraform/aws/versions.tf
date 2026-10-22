terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
  }

  # The wizard supplies real values via `terraform init -backend-config`:
  #   -backend-config="bucket=<tfstate_bucket>"
  #   -backend-config="region=<aws_region>"
  # Placeholder values below let `terraform validate` succeed offline.
  # State locking is S3-native: use_lockfile writes a .tflock object next to
  # the state, so no DynamoDB table is needed. It requires Terraform >= 1.10.
  backend "s3" {
    bucket       = "REPLACE-VIA-BACKEND-CONFIG"
    key          = "qlik-lakehouse/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}
