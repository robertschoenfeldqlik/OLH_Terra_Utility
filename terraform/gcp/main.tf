# ─────────────────────────────────────────────────────────────────────────────
#  Qlik Open Lakehouse on Google Cloud - Terraform layer
#
#  Same division of labour as the AWS module: the bash / PowerShell wizards
#  create the heavy resources (VPC network, subnetwork, firewall, Cloud KMS
#  key, service accounts, GCS buckets) via gcloud, and this configuration:
#
#    1.  References those resources via `data` sources so we never double-create.
#    2.  Asserts the discovered values match the project (drift detection).
#    3.  Asserts the OLH prerequisites the CLI pass cannot check for itself.
#    4.  Creates the auxiliary resources the wizard *names* but does not build:
#          - BigLake catalog + database (the Google Lakehouse Runtime Catalog)
#          - BigQuery dataset for zero-copy mirroring (GCP-only OLH feature)
#          - the data-plane IAM grants on the node service account
#          - Workload Identity Federation for the QTC tenant
#          - Secret Manager entries (the GCP analogue of SSM Parameter Store)
#    5.  Surfaces every value Qlik Talend Cloud needs as outputs.
#
#  Where AWS has a Kinesis stream in the prerequisite list, GCP has nothing:
#  the Private Preview covers CDC and SaaS sources only. Streaming on GCP is
#  Kafka and GCS, and arrives later in the preview.
# ─────────────────────────────────────────────────────────────────────────────

# ── Project sanity check ────────────────────────────────────────────────────
data "google_project" "current" {}

resource "null_resource" "project_sanity" {
  lifecycle {
    precondition {
      condition     = data.google_project.current.project_id == var.gcp_project_id
      error_message = "Configured gcp_project_id (${var.gcp_project_id}) does not match the credentials in use (${data.google_project.current.project_id})."
    }
    precondition {
      condition     = data.google_project.current.number == var.gcp_project_number
      error_message = "Configured gcp_project_number (${var.gcp_project_number}) does not match project ${data.google_project.current.project_id}, whose number is ${data.google_project.current.number}."
    }
  }
}

# ── Existing infrastructure (created by the wizard via gcloud) ──────────────
data "google_compute_network" "olh" {
  name = var.network_name
}

data "google_compute_subnetwork" "olh" {
  name   = var.subnetwork_name
  region = var.gcp_region
}

data "google_kms_key_ring" "olh" {
  name     = local.kms_keyring_name
  location = local.kms_location
}

data "google_kms_crypto_key" "olh" {
  name     = local.kms_key_name
  key_ring = data.google_kms_key_ring.olh.id
}

data "google_service_account" "mgmt" {
  account_id = var.mgmt_service_account_email
}

data "google_service_account" "node" {
  account_id = var.node_service_account_email
}

data "google_storage_bucket" "table" {
  name = var.gcs_table_bucket
}

data "google_storage_bucket" "landing" {
  name = var.gcs_landing_bucket
}

data "google_storage_bucket" "config" {
  name = var.gcs_config_bucket
}

# ── Locals derived from inputs ──────────────────────────────────────────────
locals {
  prefix = "${var.initials}-${var.workload}-${var.env}"

  # projects/<p>/locations/<l>/keyRings/<r>/cryptoKeys/<k>
  kms_parts        = split("/", var.kms_key_id)
  kms_location     = local.kms_parts[3]
  kms_keyring_name = local.kms_parts[5]
  kms_key_name     = local.kms_parts[7]

  catalog_name   = var.biglake_catalog_name != "" ? var.biglake_catalog_name : "${var.initials}_${var.workload}_${var.env}_catalog"
  database_name  = "${var.initials}_${var.workload}_${var.env}_db"
  mirror_dataset = var.bigquery_mirror_dataset != "" ? var.bigquery_mirror_dataset : "${var.initials}_${var.workload}_${var.env}_mirror"

  secret_prefix = "${var.initials}-${var.workload}-${var.env}"

  olh_buckets = distinct([var.gcs_table_bucket, var.gcs_landing_bucket, var.gcs_config_bucket])

  node_member = "serviceAccount:${var.node_service_account_email}"
  mgmt_member = "serviceAccount:${var.mgmt_service_account_email}"

  use_wif = var.qtc_auth_method == "workload_identity"

  # Zones must sit inside the configured region, otherwise the MIG cannot use
  # the regional subnetwork.
  zones_outside_region = [for z in var.gcp_zones : z if !startswith(z, "${var.gcp_region}-")]

  wif_pool_id = "${local.prefix}-qtc-pool"
}

# ── OLH prerequisite assertions ─────────────────────────────────────────────
# The GCP counterparts of the AWS checks: these fail at plan time, before a
# lakehouse cluster can be pointed at a project that cannot actually run it.
resource "null_resource" "olh_prerequisites" {
  lifecycle {
    precondition {
      condition     = data.google_compute_subnetwork.olh.private_ip_google_access
      error_message = "Private Google Access is off on subnetwork ${var.subnetwork_name}. OLH nodes reach Cloud Storage and the catalog over Google APIs; without it that traffic has to egress to the internet. This is the GCP counterpart of the S3 gateway endpoint on AWS. Fix with: gcloud compute networks subnets update ${var.subnetwork_name} --region ${var.gcp_region} --enable-private-ip-google-access"
    }
    precondition {
      condition     = length(local.zones_outside_region) == 0
      error_message = "These zones are not in region ${var.gcp_region}: ${join(", ", local.zones_outside_region)}. The cluster MIG cannot use a regional subnetwork from outside its region."
    }
    precondition {
      condition     = data.google_compute_subnetwork.olh.ip_cidr_range == var.subnetwork_cidr
      error_message = "subnetwork_cidr (${var.subnetwork_cidr}) does not match the live range of ${var.subnetwork_name} (${data.google_compute_subnetwork.olh.ip_cidr_range})."
    }
    precondition {
      condition     = var.mgmt_service_account_email != var.node_service_account_email
      error_message = "mgmt_service_account_email and node_service_account_email must be different identities. QTC impersonates the management account from outside the project; the node account is attached to the VMs and holds the data-plane grants. Collapsing them into one account is the mistake the AWS wizard used to make with mgmt_role_arn."
    }
    precondition {
      condition     = !local.use_wif || var.qtc_oidc_issuer_uri != ""
      error_message = "qtc_auth_method is workload_identity, so qtc_oidc_issuer_uri must be set to the issuer Qlik Talend Cloud presents tokens from."
    }
    precondition {
      condition     = !local.use_wif || length(local.wif_pool_id) <= 32
      error_message = "The Workload Identity pool ID derived from your naming (${local.wif_pool_id}) is ${length(local.wif_pool_id)} characters; Google caps it at 32. Shorten initials or workload."
    }
  }
}

# ── Google Lakehouse Runtime Catalog (the Glue Data Catalog counterpart) ────
resource "google_biglake_catalog" "olh" {
  name     = local.catalog_name
  location = var.gcp_region
}

resource "google_biglake_database" "olh" {
  name    = local.database_name
  catalog = google_biglake_catalog.olh.id
  type    = "HIVE"

  hive_options {
    location_uri = "gs://${var.gcs_table_bucket}/${local.prefix}"
    parameters = {
      owner   = var.tag_owner
      purpose = "qlik-open-lakehouse"
    }
  }
}

# ── BigQuery mirror dataset (GCP-only: no AWS equivalent) ───────────────────
# A CMEK-encrypted dataset is only creatable once BigQuery's own service agent
# can use the key, so that grant has to land first.
data "google_bigquery_default_service_account" "bq" {}

resource "google_kms_crypto_key_iam_member" "bigquery_cmek" {
  crypto_key_id = var.kms_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_bigquery_default_service_account.bq.email}"
}

resource "google_bigquery_dataset" "mirror" {
  depends_on = [google_kms_crypto_key_iam_member.bigquery_cmek]

  dataset_id    = local.mirror_dataset
  friendly_name = "Qlik Open Lakehouse mirror for ${local.prefix}"
  description   = "Zero-copy mirroring target for ${local.prefix}. Populated by Qlik Open Lakehouse; do not write to it by hand."
  location      = var.gcp_region

  default_encryption_configuration {
    kms_key_name = var.kms_key_id
  }
}

# ── Data-plane grants for the node service account ──────────────────────────
# The GCP counterpart of the EC2 node policy: read/write the three buckets,
# use the CMEK, and maintain tables in the catalog.
resource "google_storage_bucket_iam_member" "node_objects" {
  for_each = toset(local.olh_buckets)

  bucket = each.value
  role   = "roles/storage.objectAdmin"
  member = local.node_member
}

resource "google_storage_bucket_iam_member" "node_bucket_read" {
  for_each = toset(local.olh_buckets)

  bucket = each.value
  role   = "roles/storage.legacyBucketReader"
  member = local.node_member
}

resource "google_kms_crypto_key_iam_member" "node_cmek" {
  crypto_key_id = var.kms_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = local.node_member
}

# roles/biglake.editor (Beta) is the narrowest predefined role that still lets
# the node maintain tables: biglake.tables.create/update/delete, the partition
# and data permissions, lock, and databases.* CRUD. Compared with
# roles/biglake.admin it drops catalogs/namespaces setIamPolicy and
# biglake.tables.register. If OLH turns out to register pre-existing Iceberg
# metadata into the catalog, it needs register and therefore roles/biglake.admin.
#
# The grant has to stay project-wide. google_biglake_catalog is a BigLake v1
# projects/<p>/locations/<l>/catalogs/<c> resource, and that API has only
# create/delete/get/list, with no setIamPolicy. So there is no catalog- or
# database-level policy to bind to, and provider v8.3.0 has no
# google_biglake_catalog_iam_* or google_biglake_database_iam_* resource.
# Resource-level BigLake IAM exists only on the newer projects/<p>/catalogs/<c>
# hive and Iceberg catalogs, a different resource family. That is why the AWS
# module can scope glue:* to one database and its tables and this one cannot.
resource "google_project_iam_member" "node_catalog" {
  project = var.gcp_project_id
  role    = "roles/biglake.editor"
  member  = local.node_member
}

resource "google_bigquery_dataset_iam_member" "node_mirror" {
  dataset_id = google_bigquery_dataset.mirror.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = local.node_member
}

# The management account has to be able to hand the node account to a VM it
# creates, which is a distinct permission from using the account itself.
resource "google_service_account_iam_member" "mgmt_can_use_node" {
  service_account_id = data.google_service_account.node.name
  role               = "roles/iam.serviceAccountUser"
  member             = local.mgmt_member
}

# ── Workload Identity Federation for the QTC tenant ─────────────────────────
#
#  ASSUMPTION - see the qtc_auth_method variable. This is the GCP shape of the
#  AWS "assume role with ExternalId" trust OLH uses today: the tenant ID is the
#  allowed audience, so a token minted for another tenant is rejected at the
#  provider before it ever reaches the service account.
#
resource "google_iam_workload_identity_pool" "qtc" {
  count = local.use_wif ? 1 : 0

  workload_identity_pool_id = local.wif_pool_id
  display_name              = "Qlik Talend Cloud"
  description               = "Federated access for Qlik Open Lakehouse management of ${local.prefix}"
}

resource "google_iam_workload_identity_pool_provider" "qtc" {
  count = local.use_wif ? 1 : 0

  workload_identity_pool_id          = google_iam_workload_identity_pool.qtc[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "${local.prefix}-qtc-oidc"
  display_name                       = "QTC OIDC"

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }

  # Unset (null) unless qtc_workload_identity_attribute_condition is supplied.
  attribute_condition = var.qtc_workload_identity_attribute_condition != "" ? var.qtc_workload_identity_attribute_condition : null

  oidc {
    issuer_uri        = var.qtc_oidc_issuer_uri
    allowed_audiences = [var.qtc_tenant_id]
  }
}

# With qtc_workload_identity_subject set, only that subject can impersonate the
# management service account. With it empty, the member is every identity in the
# pool (principalSet://.../*). In that case, unless
# qtc_workload_identity_attribute_condition is set, any identity the issuer will
# mint a token for with your tenant ID as the audience can impersonate this
# account. The audience is then the only gate. This is deliberate while Qlik has
# not published the subject claim QTC presents. Set either variable to close it.
resource "google_service_account_iam_member" "qtc_impersonation" {
  count = local.use_wif ? 1 : 0

  service_account_id = data.google_service_account.mgmt.name
  role               = "roles/iam.workloadIdentityUser"
  member = (
    var.qtc_workload_identity_subject != ""
    ? "principal://iam.googleapis.com/${google_iam_workload_identity_pool.qtc[0].name}/subject/${var.qtc_workload_identity_subject}"
    : "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.qtc[0].name}/*"
  )
}

# ── Secret Manager (the SSM Parameter Store counterpart) ────────────────────
locals {
  olh_secrets = {
    network_name       = data.google_compute_network.olh.name
    subnetwork_name    = data.google_compute_subnetwork.olh.name
    subnetwork_cidr    = data.google_compute_subnetwork.olh.ip_cidr_range
    firewall_rule      = var.firewall_rule_name
    kms_key_id         = var.kms_key_id
    mgmt_service_acct  = var.mgmt_service_account_email
    node_service_acct  = var.node_service_account_email
    gcs_table_bucket   = var.gcs_table_bucket
    gcs_landing_bucket = var.gcs_landing_bucket
    gcs_config_bucket  = var.gcs_config_bucket
    biglake_catalog    = google_biglake_catalog.olh.name
    biglake_database   = google_biglake_database.olh.name
    bigquery_mirror    = google_bigquery_dataset.mirror.dataset_id
    gcp_zones          = join(",", var.gcp_zones)
  }
}

resource "google_secret_manager_secret" "olh" {
  for_each = local.olh_secrets

  secret_id = "${local.secret_prefix}-${replace(each.key, "_", "-")}"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "olh" {
  for_each = local.olh_secrets

  secret      = google_secret_manager_secret.olh[each.key].id
  secret_data = each.value
}

# The tenant ID is held separately so it is obvious in the console that this
# one is the sensitive binding value, the way kms_key_arn is a SecureString on
# the AWS side.
resource "google_secret_manager_secret" "qtc_tenant_id" {
  secret_id = "${local.secret_prefix}-qtc-tenant-id"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "qtc_tenant_id" {
  secret      = google_secret_manager_secret.qtc_tenant_id.id
  secret_data = var.qtc_tenant_id
}
