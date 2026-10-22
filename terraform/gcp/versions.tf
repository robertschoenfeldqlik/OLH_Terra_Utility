terraform {
  required_version = ">= 1.8.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
  }

  # The wizard supplies real values via `terraform init -backend-config`:
  #   -backend-config="bucket=<tfstate_bucket>"
  # Placeholder value below lets `terraform validate` succeed offline.
  backend "gcs" {
    bucket = "replace-via-backend-config"
    prefix = "qlik-lakehouse"
  }
}
