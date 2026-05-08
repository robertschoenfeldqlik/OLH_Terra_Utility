# ─────────────────────────────────────────────────────────────────────────────
#  Qlik Open Lakehouse - Terraform layer
#
#  The bash / PowerShell wizards already create the heavy AWS resources
#  (Security Group, KMS key, IAM role + instance profile, S3 buckets, Kinesis)
#  via the AWS CLI. This Terraform configuration:
#
#    1.  References those resources via `data` sources so we don't double-create.
#    2.  Asserts the discovered values match the AWS account (drift detection).
#    3.  Creates the auxiliary resources the wizard *names* but does not build:
#          - Glue Catalog Database (used by Qlik Talend Cloud)
#          - SSM Parameter Store entries at /<initials>/<workload>/<env>/...
#    4.  Surfaces every value Qlik Talend Cloud needs as outputs.
# ─────────────────────────────────────────────────────────────────────────────

# ── Account sanity check ────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

resource "null_resource" "account_sanity" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.aws_account_id
      error_message = "Configured aws_account_id (${var.aws_account_id}) does not match the credentials in use (${data.aws_caller_identity.current.account_id})."
    }
  }
}

# ── Existing infrastructure (created by the wizard via aws cli) ─────────────
data "aws_vpc" "main" {
  id = var.vpc_id
}

data "aws_security_group" "olh" {
  id = var.security_group_id
}

data "aws_kms_key" "olh" {
  key_id = var.kms_key_arn
}

data "aws_iam_role" "mgmt" {
  name = element(split("/", var.mgmt_role_arn), length(split("/", var.mgmt_role_arn)) - 1)
}

data "aws_iam_instance_profile" "olh" {
  name = element(split("/", var.instance_profile_arn), length(split("/", var.instance_profile_arn)) - 1)
}

data "aws_s3_bucket" "iceberg" {
  bucket = var.s3_bucket_name
}

data "aws_kinesis_stream" "cdc" {
  name = var.kinesis_stream_name
}

# ── Locals derived from inputs ──────────────────────────────────────────────
locals {
  prefix       = "${var.initials}-${var.workload}-${var.env}"
  glue_db_name = "${var.initials}_${var.workload}_${var.env}_db_glue"
  ssm_path     = "/${var.initials}/${var.workload}/${var.env}"
}

# ── Glue Catalog Database (consumed by QTC for the Open Lakehouse catalog) ──
resource "aws_glue_catalog_database" "olh" {
  name        = local.glue_db_name
  description = "Qlik Open Lakehouse catalog for ${local.prefix}"
}

# ── SSM Parameters for QTC Network Integration ──────────────────────────────
resource "aws_ssm_parameter" "vpc_id" {
  name  = "${local.ssm_path}/vpc_id"
  type  = "String"
  value = var.vpc_id
}

resource "aws_ssm_parameter" "vpc_cidr" {
  name  = "${local.ssm_path}/vpc_cidr"
  type  = "String"
  value = var.vpc_cidr
}

resource "aws_ssm_parameter" "security_group_id" {
  name  = "${local.ssm_path}/security_group_id"
  type  = "String"
  value = var.security_group_id
}

resource "aws_ssm_parameter" "kms_key_arn" {
  name  = "${local.ssm_path}/kms_key_arn"
  type  = "SecureString"
  value = var.kms_key_arn
}

resource "aws_ssm_parameter" "mgmt_role_arn" {
  name  = "${local.ssm_path}/mgmt_role_arn"
  type  = "String"
  value = var.mgmt_role_arn
}

resource "aws_ssm_parameter" "instance_profile_arn" {
  name  = "${local.ssm_path}/instance_profile_arn"
  type  = "String"
  value = var.instance_profile_arn
}

resource "aws_ssm_parameter" "s3_bucket_name" {
  name  = "${local.ssm_path}/s3_iceberg_bucket"
  type  = "String"
  value = var.s3_bucket_name
}

resource "aws_ssm_parameter" "kinesis_stream_name" {
  name  = "${local.ssm_path}/kinesis_stream_name"
  type  = "String"
  value = var.kinesis_stream_name
}

resource "aws_ssm_parameter" "glue_database" {
  name  = "${local.ssm_path}/glue_database"
  type  = "String"
  value = aws_glue_catalog_database.olh.name
}
