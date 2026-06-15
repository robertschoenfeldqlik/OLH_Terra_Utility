# ── Naming / identity ────────────────────────────────────────────────────────
variable "initials" {
  description = "Owner code used in resource names and the Owner tag (2-6 lowercase alphanumeric, matching the wizard prompt)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.initials))
    error_message = "initials must be 2-6 lowercase alphanumeric characters (matches the wizard's input rule)."
  }
}

variable "workload" {
  description = "Short workload identifier (e.g. olh)."
  type        = string
}

variable "env" {
  description = "Environment: dev | uat | prod (the values the wizards offer); qa and stg also accepted for manual tfvars."
  type        = string
  validation {
    condition     = contains(["dev", "uat", "qa", "stg", "prod"], var.env)
    error_message = "env must be one of dev, uat, qa, stg, prod."
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
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.tfstate_bucket))
    error_message = "tfstate_bucket must be a valid S3 bucket name (3-63 chars, lowercase letters, digits, hyphens, dots)."
  }
}

# ── Existing network ─────────────────────────────────────────────────────────
variable "vpc_id" {
  description = "Existing VPC ID where OLH workloads run."
  type        = string
  validation {
    # Tolerates the DRYRUN placeholder (vpc-DRYRUN) while rejecting empty / wrong-resource values.
    condition     = can(regex("^vpc-[a-zA-Z0-9]+$", var.vpc_id))
    error_message = "vpc_id must look like vpc-xxxxxxxx (a VPC ID), not empty or another resource's ID."
  }
}

variable "vpc_cidr" {
  description = "CIDR range of the VPC."
  type        = string
  validation {
    condition     = can(regex("^([0-9]{1,3}[.]){3}[0-9]{1,3}/[0-9]{1,2}$", var.vpc_cidr))
    error_message = "vpc_cidr must be a CIDR block, e.g. 10.0.0.0/16."
  }
}

variable "security_group_id" {
  description = "Existing Security Group attached to OLH compute (created by the wizard via aws cli)."
  type        = string
  validation {
    condition     = can(regex("^sg-[a-zA-Z0-9]+$", var.security_group_id))
    error_message = "security_group_id must look like sg-xxxxxxxx, not empty or another resource's ID."
  }
}

# ── Existing security / IAM ──────────────────────────────────────────────────
variable "kms_key_arn" {
  description = "ARN of the symmetric KMS CMK used to encrypt OLH data."
  type        = string
  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN, e.g. arn:aws:kms:<region>:<account>:key/<id>."
  }
}

variable "mgmt_role_arn" {
  description = "ARN of the IAM management role for the OLH control plane."
  type        = string
  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.mgmt_role_arn))
    error_message = "mgmt_role_arn must be an IAM role ARN, e.g. arn:aws:iam::<account>:role/<name>."
  }
}

variable "instance_profile_arn" {
  description = "ARN of the IAM instance profile attached to OLH EC2 nodes."
  type        = string
  validation {
    # This is the field that previously slipped through empty and failed at the
    # data-source lookup; reject anything that isn't an instance-profile ARN.
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:instance-profile/.+$", var.instance_profile_arn))
    error_message = "instance_profile_arn must be an IAM instance profile ARN, e.g. arn:aws:iam::<account>:instance-profile/<name>."
  }
}

# ── Existing storage / streaming ─────────────────────────────────────────────
variable "s3_bucket_name" {
  description = "Name of the primary S3 Iceberg data bucket."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.s3_bucket_name))
    error_message = "s3_bucket_name must be a valid S3 bucket name (3-63 chars, lowercase letters, digits, hyphens, dots)."
  }
}

variable "kinesis_stream_name" {
  description = "Name of the Kinesis Data Stream used for CDC."
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9_.-]{1,128}$", var.kinesis_stream_name))
    error_message = "kinesis_stream_name must be 1-128 chars of letters, digits, underscores, dots, or hyphens."
  }
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
