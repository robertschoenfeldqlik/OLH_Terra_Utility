terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80"
    }
  }

  # The wizard supplies real values via `terraform init -backend-config`:
  #   -backend-config="bucket=<tfstate_bucket>"
  #   -backend-config="region=<aws_region>"
  # Placeholder values below let `terraform validate` succeed offline.
  backend "s3" {
    bucket = "REPLACE-VIA-BACKEND-CONFIG"
    key    = "qlik-lakehouse/terraform.tfstate"
    region = "us-east-1"
  }
}
