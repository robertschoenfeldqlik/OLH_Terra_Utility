provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Owner       = var.tag_owner
      Environment = var.tag_env
      Workload    = var.tag_workload
      Application = "open-lakehouse"
      CreateDate  = var.tag_createdate
      ManagedBy   = "terraform"
    }
  }
}
