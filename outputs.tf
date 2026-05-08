# ─────────────────────────────────────────────────────────────────────────────
#  Outputs - the values Qlik Talend Cloud (QTC) needs for the Network
#  Integration and Lakehouse Cluster setup. Mirrors qlik-network-integration.txt.
# ─────────────────────────────────────────────────────────────────────────────

output "aws_account_id" {
  description = "AWS account ID where OLH runs."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region."
  value       = var.aws_region
}

output "vpc_id" {
  description = "VPC ID for the OLH workload."
  value       = data.aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR range of the OLH VPC."
  value       = data.aws_vpc.main.cidr_block
}

output "security_group_id" {
  description = "Security Group ID attached to OLH compute."
  value       = data.aws_security_group.olh.id
}

output "kms_key_arn" {
  description = "KMS key ARN for OLH data encryption."
  value       = data.aws_kms_key.olh.arn
}

output "mgmt_role_arn" {
  description = "IAM management role ARN."
  value       = data.aws_iam_role.mgmt.arn
}

output "instance_profile_arn" {
  description = "EC2 instance profile ARN."
  value       = data.aws_iam_instance_profile.olh.arn
}

output "s3_iceberg_bucket" {
  description = "Primary Iceberg S3 bucket name."
  value       = data.aws_s3_bucket.iceberg.bucket
}

output "kinesis_stream_name" {
  description = "Kinesis Data Stream name."
  value       = data.aws_kinesis_stream.cdc.name
}

output "kinesis_stream_arn" {
  description = "Kinesis Data Stream ARN."
  value       = data.aws_kinesis_stream.cdc.arn
}

output "glue_database" {
  description = "Glue Catalog database created for OLH."
  value       = aws_glue_catalog_database.olh.name
}

output "ssm_path" {
  description = "SSM Parameter Store base path holding QTC integration values."
  value       = local.ssm_path
}

output "qtc_summary" {
  description = "Single object containing every value QTC needs - copy/paste friendly."
  value = {
    aws_account_id       = data.aws_caller_identity.current.account_id
    aws_region           = var.aws_region
    vpc_id               = data.aws_vpc.main.id
    vpc_cidr             = data.aws_vpc.main.cidr_block
    security_group_id    = data.aws_security_group.olh.id
    kms_key_arn          = data.aws_kms_key.olh.arn
    mgmt_role_arn        = data.aws_iam_role.mgmt.arn
    instance_profile_arn = data.aws_iam_instance_profile.olh.arn
    s3_iceberg_bucket    = data.aws_s3_bucket.iceberg.bucket
    kinesis_stream_arn   = data.aws_kinesis_stream.cdc.arn
    glue_database        = aws_glue_catalog_database.olh.name
    ssm_path             = local.ssm_path
  }
}
