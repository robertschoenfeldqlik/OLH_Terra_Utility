# ── Naming / identity ────────────────────────────────────────────────────────
variable "initials" {
  description = "3-letter user / owner code used in resource names and the Owner tag."
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z]{2,5}$", var.initials))
    error_message = "initials must be 2-5 alphabetic characters."
  }
}

variable "workload" {
  description = "Short workload identifier (e.g. olh)."
  type        = string
}

variable "env" {
  description = "Environment: dev | qa | prod."
  type        = string
  validation {
    condition     = contains(["dev", "qa", "stg", "prod"], var.env)
    error_message = "env must be one of dev, qa, stg, prod."
  }
}

# ── AWS account / region ─────────────────────────────────────────────────────
variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
}

variable "aws_account_id" {
  description = "12-digit AWS account ID (used for sanity-checking only)."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be exactly 12 digits."
  }
}

variable "tfstate_bucket" {
  description = "S3 bucket holding remote Terraform state (configured via -backend-config at init time)."
  type        = string
}

# ── Existing network ─────────────────────────────────────────────────────────
variable "vpc_id" {
  description = "Existing VPC ID where OLH workloads run."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR range of the VPC."
  type        = string
}

variable "security_group_id" {
  description = "Existing Security Group attached to OLH compute (created by the wizard via aws cli)."
  type        = string
}

# ── Existing security / IAM ──────────────────────────────────────────────────
variable "kms_key_arn" {
  description = "ARN of the symmetric KMS CMK used to encrypt OLH data."
  type        = string
}

variable "mgmt_role_arn" {
  description = "ARN of the IAM management role for the OLH control plane."
  type        = string
}

variable "instance_profile_arn" {
  description = "ARN of the IAM instance profile attached to OLH EC2 nodes."
  type        = string
}

# ── Existing storage / streaming ─────────────────────────────────────────────
variable "s3_bucket_name" {
  description = "Name of the primary S3 Iceberg data bucket."
  type        = string
}

variable "kinesis_stream_name" {
  description = "Name of the Kinesis Data Stream used for CDC."
  type        = string
}

variable "kinesis_shards" {
  description = "Shard count for the Kinesis stream (informational; stream itself is referenced as a data source)."
  type        = number
  default     = 2
}

# ── Tags ─────────────────────────────────────────────────────────────────────
variable "tag_owner" {
  description = "Owner tag value (typically the user's initials)."
  type        = string
}

variable "tag_env" {
  description = "Environment tag value."
  type        = string
}

variable "tag_workload" {
  description = "Workload tag value."
  type        = string
  default     = "qlik-olh"
}

variable "tag_createdate" {
  description = "CreateDate tag value (YYYY-MM-DD)."
  type        = string
}
