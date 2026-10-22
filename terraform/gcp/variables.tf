# ─────────────────────────────────────────────────────────────────────────────
#  Qlik Open Lakehouse on Google Cloud - input variables
#
#  Mirrors terraform/aws/variables.tf. Where a GCP service stands in for an AWS
#  one, the description says so.
#
#  Status: OLH on GCP entered Private Preview on 2 Sep 2026; GA is planned for
#  Q4 2026. Preview scope is CDC and SaaS sources only - streaming (Kafka/GCS)
#  and Qlik Replicate sources arrive later in the preview. That is why there is
#  no queue/stream resource here the way there is on AWS.
# ─────────────────────────────────────────────────────────────────────────────

# ── Naming / identity ────────────────────────────────────────────────────────
variable "initials" {
  description = "Owner code used in resource names and the owner label (2-6 lowercase alphanumeric, matching the wizard prompt)."
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

# ── Project / region ─────────────────────────────────────────────────────────
variable "gcp_project_id" {
  description = "Google Cloud project ID hosting the lakehouse (the GCP analogue of aws_account_id)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.gcp_project_id))
    error_message = "gcp_project_id must be 6-30 chars, start with a letter, and contain only lowercase letters, digits and hyphens."
  }
}

variable "gcp_project_number" {
  description = "Numeric project number, used to build the Workload Identity principal strings."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{6,20}$", var.gcp_project_number))
    error_message = "gcp_project_number must be the numeric project number, not the project ID."
  }
}

variable "gcp_region" {
  description = "Region for all regional resources. Must match the region of the GCS buckets and the subnetwork."
  type        = string
  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.gcp_region))
    error_message = "gcp_region must look like us-central1 or europe-west4."
  }
}

variable "gcp_zones" {
  description = "Zones the lakehouse MIG spreads Spot VMs across. OLH requires at least two, mirroring the two-AZ rule on AWS."
  type        = list(string)
  validation {
    condition     = length(var.gcp_zones) >= 2
    error_message = "OLH requires at least two zones so the managed instance group survives a single-zone Spot reclaim."
  }
  validation {
    condition     = alltrue([for z in var.gcp_zones : can(regex("^[a-z]+-[a-z]+[0-9]-[a-z]$", z))])
    error_message = "every entry in gcp_zones must look like us-central1-a."
  }
}

variable "tfstate_bucket" {
  description = "GCS bucket holding remote Terraform state (configured via -backend-config at init time)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.tfstate_bucket))
    error_message = "tfstate_bucket must be a valid GCS bucket name (3-63 chars, lowercase letters, digits, hyphens, underscores, dots)."
  }
}

# ── Existing network ─────────────────────────────────────────────────────────
variable "network_name" {
  description = "Existing VPC network the lakehouse runs in (the GCP analogue of vpc_id)."
  type        = string
  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.network_name))
    error_message = "network_name must be a valid GCP resource name: lowercase, starting with a letter, up to 63 chars."
  }
}

variable "subnetwork_name" {
  description = "Existing regional subnetwork for the agent VM and the cluster MIG. Private Google Access must be on so nodes reach Google APIs without egressing to the internet - the GCP counterpart of the S3 gateway endpoint."
  type        = string
  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.subnetwork_name))
    error_message = "subnetwork_name must be a valid GCP resource name."
  }
}

variable "subnetwork_cidr" {
  description = "Primary CIDR range of the subnetwork (the GCP analogue of vpc_cidr)."
  type        = string
  validation {
    condition     = can(regex("^([0-9]{1,3}[.]){3}[0-9]{1,3}/[0-9]{1,2}$", var.subnetwork_cidr))
    error_message = "subnetwork_cidr must be a CIDR block, e.g. 10.0.0.0/16."
  }
}

variable "firewall_rule_name" {
  description = "Firewall rule allowing intra-subnet traffic between lakehouse nodes (the GCP analogue of the OLH security group)."
  type        = string
  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.firewall_rule_name))
    error_message = "firewall_rule_name must be a valid GCP resource name."
  }
}

# ── Existing security / IAM ──────────────────────────────────────────────────
variable "kms_key_id" {
  description = "Full resource ID of the symmetric Cloud KMS key used as the CMEK for the lakehouse buckets."
  type        = string
  validation {
    condition     = can(regex("^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$", var.kms_key_id))
    error_message = "kms_key_id must be a full Cloud KMS key ID, e.g. projects/<p>/locations/<l>/keyRings/<r>/cryptoKeys/<k>."
  }
}

variable "mgmt_service_account_email" {
  description = "Service account Qlik Talend Cloud impersonates to manage resources on your behalf - the GCP analogue of the AWS management role. Deliberately distinct from the node service account."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]{6,30}@[a-z0-9-]+[.]iam[.]gserviceaccount[.]com$", var.mgmt_service_account_email))
    error_message = "mgmt_service_account_email must be a service account email, e.g. name@project.iam.gserviceaccount.com."
  }
}

variable "node_service_account_email" {
  description = "Service account attached to the agent VM and the cluster MIG - the GCP analogue of the EC2 instance profile. Carries the GCS/KMS/BigLake data-plane permissions."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]{6,30}@[a-z0-9-]+[.]iam[.]gserviceaccount[.]com$", var.node_service_account_email))
    error_message = "node_service_account_email must be a service account email, e.g. name@project.iam.gserviceaccount.com."
  }
}

# ── Qlik Talend Cloud tenant binding ─────────────────────────────────────────
#
#  ASSUMPTION - CONFIRM BEFORE A REAL DEPLOYMENT.
#  Qlik has not published how QTC authenticates into a customer GCP project for
#  the Private Preview. This module assumes Workload Identity Federation, the
#  GCP counterpart of the "assume role with ExternalId" pattern OLH uses on AWS
#  today. If the preview onboarding pack specifies a service-account key or a
#  Qlik-owned service account instead, only this section has to change.
#
variable "qtc_auth_method" {
  description = "How QTC authenticates into this project. 'workload_identity' builds a WIF pool/provider and grants impersonation on the management service account; 'preauthorized_sa' skips the pool and assumes impersonation was granted out of band."
  type        = string
  default     = "workload_identity"
  validation {
    condition     = contains(["workload_identity", "preauthorized_sa"], var.qtc_auth_method)
    error_message = "qtc_auth_method must be workload_identity or preauthorized_sa."
  }
}

variable "qtc_oidc_issuer_uri" {
  description = "OIDC issuer URI Qlik Talend Cloud presents tokens from. Required when qtc_auth_method is workload_identity."
  type        = string
  default     = ""
  validation {
    condition     = var.qtc_oidc_issuer_uri == "" || can(regex("^https://", var.qtc_oidc_issuer_uri))
    error_message = "qtc_oidc_issuer_uri must be an https URL."
  }
}

variable "qtc_tenant_id" {
  description = "Your QTC tenant identifier. Used as the allowed audience on the WIF provider, so it plays the role the AWS ExternalId plays today: it stops another tenant's token being accepted."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.qtc_tenant_id) > 0
    error_message = "qtc_tenant_id must be supplied - copy it from Administration > Network integrations in QTC."
  }
}

# The next two variables are the GCP counterpart of the AWS sts:ExternalId gate.
# On AWS the management role's trust policy refuses an AssumeRole that does not
# carry your ExternalId. Here the provider can refuse a token that fails a CEL
# condition, and the service account can refuse a token whose subject is not the
# one QTC presents. Both default to empty because Qlik has not published the
# claims QTC sends for the GCP Private Preview; with both empty the allowed
# audience (qtc_tenant_id) is the only gate. Set them as soon as Qlik confirms
# the claims.
variable "qtc_workload_identity_subject" {
  description = "Exact `sub` claim QTC presents in its OIDC token. When set, the impersonation grant on the management service account narrows from every identity in the pool (principalSet://.../*) to this one principal (principal://iam.googleapis.com/<pool>/subject/<value>). GCP counterpart of the AWS sts:ExternalId gate. Empty (the default) keeps the pool-wide grant."
  type        = string
  default     = ""
}

variable "qtc_workload_identity_attribute_condition" {
  description = "Raw CEL attribute condition applied to the Workload Identity provider when set, e.g. \"assertion.sub == 'my-qtc-subject'\". Google evaluates it for every token presented to the provider and rejects the credential when it is false, so it blocks a token before the service-account binding is consulted. It may reference assertion.* claims and any attribute mapped in attribute_mapping (only google.subject is mapped today). GCP counterpart of the AWS sts:ExternalId gate. Empty (the default) applies no condition."
  type        = string
  default     = ""
}

# ── Existing storage ─────────────────────────────────────────────────────────
variable "gcs_table_bucket" {
  description = "Bucket holding the Iceberg table storage (the GCP analogue of the S3 Iceberg bucket)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.gcs_table_bucket))
    error_message = "gcs_table_bucket must be a valid GCS bucket name."
  }
}

variable "gcs_landing_bucket" {
  description = "Landing bucket the lakehouse cluster stages incoming data in."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.gcs_landing_bucket))
    error_message = "gcs_landing_bucket must be a valid GCS bucket name."
  }
}

variable "gcs_config_bucket" {
  description = "Config bucket the lakehouse cluster keeps runtime configuration in."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.gcs_config_bucket))
    error_message = "gcs_config_bucket must be a valid GCS bucket name."
  }
}

# ── Catalog & mirroring ──────────────────────────────────────────────────────
variable "biglake_catalog_name" {
  description = "Name for the BigLake catalog backing the Iceberg tables. Qlik calls this the Google Lakehouse Runtime Catalog; it is the GCP counterpart of the AWS Glue Data Catalog. Leave empty to derive it from the prefix."
  type        = string
  default     = ""
}

variable "bigquery_mirror_dataset" {
  description = "BigQuery dataset that zero-copy mirroring writes into. Mirroring to BigQuery is a GCP-only OLH feature with no AWS equivalent. Leave empty to derive it from the prefix."
  type        = string
  default     = ""
}

# ── Labels (the GCP analogue of the AWS tag set) ─────────────────────────────
variable "tag_owner" {
  description = "Owner label value (typically the user's initials)."
  type        = string
}

variable "tag_env" {
  description = "Environment label value."
  type        = string
}

variable "tag_workload" {
  description = "Workload label value."
  type        = string
  default     = "qlik-olh"
}

variable "tag_createdate" {
  description = "CreateDate label value (YYYY-MM-DD)."
  type        = string
}
