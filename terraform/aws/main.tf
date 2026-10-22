# ─────────────────────────────────────────────────────────────────────────────
#  Qlik Open Lakehouse - Terraform layer
#
#  The bash / PowerShell wizards already create the heavy AWS resources
#  (Security Group, KMS key, IAM role + instance profile, S3 buckets, Kinesis)
#  via the AWS CLI. This Terraform configuration:
#
#    1.  References those resources via `data` sources so we don't double-create.
#    2.  Asserts the discovered values match the AWS account (drift detection).
#    3.  Asserts the OLH prerequisites the wizard cannot enforce on its own:
#          - the management role really is assumable by Qlik with our ExternalId
#          - at least two subnets, in two AZs, all of them public
#    4.  Creates the auxiliary resources the wizard *names* but does not build:
#          - Glue Catalog Database (used by Qlik Talend Cloud)
#          - S3 gateway VPC endpoint (an OLH network prerequisite)
#          - the data-plane IAM policy on the EC2 node role
#          - SSM Parameter Store entries at /<initials>/<workload>/<env>/...
#    5.  Surfaces every value Qlik Talend Cloud needs as outputs.
# ─────────────────────────────────────────────────────────────────────────────

# ── Account sanity check ────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

# aws, aws-us-gov or aws-cn - every ARN built below uses it, matching the
# arn:aws[a-z-]*: pattern the variable validations already accept.
data "aws_partition" "current" {}

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

# The role the EC2 nodes actually run as. Kept separate from the management
# role on purpose: QTC assumes the management role from outside the account,
# while this one is assumed by ec2.amazonaws.com and holds the S3/Kinesis/KMS
# permissions. Pointing both at the same role - as earlier versions of the
# wizard did - leaves the network integration unable to connect.
data "aws_iam_role" "node" {
  name = element(split("/", var.node_role_arn), length(split("/", var.node_role_arn)) - 1)
}

data "aws_subnet" "olh" {
  for_each = toset(var.subnet_ids)
  id       = each.value
}

data "aws_route_tables" "vpc" {
  vpc_id = var.vpc_id
}

# Every route table in the VPC, resolved individually. A per-subnet
# `data "aws_route_table"` lookup cannot answer "does this subnet reach an IGW":
# it filters on association.subnet-id, so a subnet that inherits the VPC main
# route table matches nothing and fails the read before the precondition runs.
data "aws_route_table" "by_id" {
  for_each       = toset(data.aws_route_tables.vpc.ids)
  route_table_id = each.value
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

  # The AWS provider URL-decodes AssumeRolePolicyDocument before exposing it,
  # so this is plain JSON: jsondecode works, and a substring test on an ARN is safe.
  mgmt_trust_policy = data.aws_iam_role.mgmt.assume_role_policy
  qlik_account_id   = split(":", var.qlik_proxy_role_arn)[4]

  # Statement is either a single object or a list; flatten([...]) normalises both.
  # The ExternalId values are taken only from Condition.StringEquals["sts:ExternalId"]
  # of Allow statements, so the value appearing elsewhere in the document does not count.
  mgmt_trust_statements = flatten([jsondecode(local.mgmt_trust_policy).Statement])
  mgmt_trust_external_ids = flatten([
    for s in local.mgmt_trust_statements : [
      for op, conds in try(s.Condition, {}) : [
        for k, v in conds : v if lower(k) == "sts:externalid"
      ] if lower(op) == "stringequals"
    ] if try(s.Effect, "") == "Allow"
  ])

  olh_buckets = distinct([var.s3_bucket_name, var.s3_landing_bucket, var.s3_config_bucket])
  subnet_azs  = distinct([for s in data.aws_subnet.olh : s.availability_zone])
  private_subnets = [
    for s in data.aws_subnet.olh : s.id if !s.map_public_ip_on_launch
  ]

  # Which route table governs each cluster subnet, and whether it reaches an
  # Internet Gateway. A subnet with no explicit association inherits the VPC
  # main route table.
  igw_route_tables = [
    for id, rt in data.aws_route_table.by_id : id
    if anytrue([for r in rt.routes : startswith(r.gateway_id, "igw-") if r.gateway_id != null])
  ]
  main_route_tables = [
    for id, rt in data.aws_route_table.by_id : id
    if anytrue([for a in rt.associations : a.main if a.main != null])
  ]
  main_route_table = length(local.main_route_tables) > 0 ? local.main_route_tables[0] : ""
  subnet_rt_explicit = {
    for s in var.subnet_ids : s => one([
      for id, rt in data.aws_route_table.by_id : id
      if anytrue([for a in rt.associations : a.subnet_id == s if a.subnet_id != null])
    ])
  }
  subnet_route_tables = {
    for s, rt in local.subnet_rt_explicit : s => rt == null ? local.main_route_table : rt
  }
  subnets_without_igw = [
    for s, rt in local.subnet_route_tables : s if !contains(local.igw_route_tables, rt)
  ]

  create_s3_endpoint  = var.s3_gateway_endpoint_id == ""
  s3_gateway_endpoint = local.create_s3_endpoint ? aws_vpc_endpoint.s3[0].id : var.s3_gateway_endpoint_id
}

# ── OLH prerequisite assertions ─────────────────────────────────────────────
# These are the checks the CLI provisioning pass cannot make for itself. They
# fail at plan time, before anything is created, so a misconfigured account
# never reaches the point of a lakehouse cluster that silently cannot connect.
resource "null_resource" "olh_prerequisites" {
  lifecycle {
    precondition {
      condition     = anytrue([for v in local.mgmt_trust_external_ids : tostring(v) == var.qtc_external_id])
      error_message = "The management role (${var.mgmt_role_arn}) does not require your QTC ExternalId in its trust policy. QTC presents that ExternalId when it assumes the role; without the sts:ExternalId condition the network integration cannot connect. Re-run the wizard, or add the condition by hand."
    }
    precondition {
      condition     = strcontains(local.mgmt_trust_policy, local.qlik_account_id)
      error_message = "The management role (${var.mgmt_role_arn}) does not trust the Qlik principal ${var.qlik_proxy_role_arn}. Its trust policy must name that ARN, not ec2.amazonaws.com - the EC2 trust belongs on node_role_arn instead."
    }
    precondition {
      condition     = length(local.subnet_azs) >= 2
      error_message = "OLH requires subnets in at least two Availability Zones; the ${length(var.subnet_ids)} subnet(s) supplied span only ${length(local.subnet_azs)} AZ(s): ${join(", ", local.subnet_azs)}."
    }
    precondition {
      condition     = length(local.private_subnets) == 0
      error_message = "OLH cluster subnets must auto-assign public IPs. These do not: ${join(", ", local.private_subnets)}."
    }
    precondition {
      condition     = length(local.subnets_without_igw) == 0
      error_message = "OLH cluster subnets must route to an Internet Gateway. These have no igw- route in the route table that governs them: ${join(", ", local.subnets_without_igw)}."
    }
    precondition {
      condition     = data.aws_vpc.main.cidr_block == var.vpc_cidr
      error_message = "vpc_cidr (${var.vpc_cidr}) does not match the live CIDR of ${var.vpc_id} (${data.aws_vpc.main.cidr_block}). QTC reads that value from SSM, so the wrong range would be advertised to the tenant."
    }
  }
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

# ── S3 gateway VPC endpoint ─────────────────────────────────────────────────
# An OLH network prerequisite: it keeps bucket traffic from the cluster on the
# AWS backbone instead of egressing through the Internet Gateway. AWS allows
# one gateway endpoint per VPC per service, so set s3_gateway_endpoint_id when
# the VPC already has one and this block steps aside.
resource "aws_vpc_endpoint" "s3" {
  count = local.create_s3_endpoint ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.vpc.ids

  tags = {
    Name = "${local.prefix}-s3-gateway-vpce"
  }
}

# ── Data-plane permissions for the EC2 node role ────────────────────────────
# The instance profile role needs to read and write the Iceberg, landing and
# config buckets, work the CDC stream, use the CMK, and maintain tables in the
# Glue catalog. The KMS grant here is what makes the CMK usable: the key's own
# default policy delegates to IAM, so no key-policy edit is required.
resource "aws_iam_role_policy" "node_data_plane" {
  name = "${local.prefix}-node-data-plane"
  role = data.aws_iam_role.node.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BucketLevel"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
        ]
        Resource = [for b in local.olh_buckets : "arn:${data.aws_partition.current.partition}:s3:::${b}"]
      },
      {
        Sid    = "ObjectLevel"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [for b in local.olh_buckets : "arn:${data.aws_partition.current.partition}:s3:::${b}/*"]
      },
      {
        Sid    = "CdcStream"
        Effect = "Allow"
        Action = [
          "kinesis:DescribeStream",
          "kinesis:DescribeStreamSummary",
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:ListShards",
          "kinesis:PutRecord",
          "kinesis:PutRecords",
        ]
        Resource = data.aws_kinesis_stream.cdc.arn
      },
      {
        Sid    = "EnvelopeEncryption"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
        ]
        Resource = data.aws_kms_key.olh.arn
      },
      {
        Sid    = "IcebergCatalog"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:DeleteTable",
          "glue:GetTable",
          "glue:GetTables",
          "glue:CreatePartition",
          "glue:UpdatePartition",
          "glue:DeletePartition",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:BatchCreatePartition",
          "glue:BatchGetPartition",
          "glue:BatchDeletePartition",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:catalog",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:database/${local.glue_db_name}",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:table/${local.glue_db_name}/*",
        ]
      },
    ]
  })
}

# ── Additional SSM parameters ───────────────────────────────────────────────
resource "aws_ssm_parameter" "node_role_arn" {
  name  = "${local.ssm_path}/node_role_arn"
  type  = "String"
  value = var.node_role_arn
}

resource "aws_ssm_parameter" "qtc_external_id" {
  name  = "${local.ssm_path}/qtc_external_id"
  type  = "SecureString"
  value = var.qtc_external_id
}

resource "aws_ssm_parameter" "subnet_ids" {
  name  = "${local.ssm_path}/subnet_ids"
  type  = "StringList"
  value = join(",", var.subnet_ids)
}

resource "aws_ssm_parameter" "s3_landing_bucket" {
  name  = "${local.ssm_path}/s3_landing_bucket"
  type  = "String"
  value = var.s3_landing_bucket
}

resource "aws_ssm_parameter" "s3_config_bucket" {
  name  = "${local.ssm_path}/s3_config_bucket"
  type  = "String"
  value = var.s3_config_bucket
}

resource "aws_ssm_parameter" "s3_gateway_endpoint" {
  name  = "${local.ssm_path}/s3_gateway_endpoint"
  type  = "String"
  value = local.s3_gateway_endpoint
}
