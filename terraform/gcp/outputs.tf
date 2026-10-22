# ─────────────────────────────────────────────────────────────────────────────
#  Outputs - the values Qlik Talend Cloud (QTC) needs for the Network
#  Integration and Lakehouse Cluster setup on Google Cloud.
#  Mirrors qlik-network-integration.txt.
# ─────────────────────────────────────────────────────────────────────────────

output "gcp_project_id" {
  description = "Google Cloud project where OLH runs."
  value       = data.google_project.current.project_id
}

output "gcp_project_number" {
  description = "Numeric project number."
  value       = data.google_project.current.number
}

output "gcp_region" {
  description = "Region for the lakehouse."
  value       = var.gcp_region
}

output "gcp_zones" {
  description = "Zones the cluster MIG spreads Spot VMs across."
  value       = var.gcp_zones
}

output "network_name" {
  description = "VPC network for the OLH workload."
  value       = data.google_compute_network.olh.name
}

output "network_self_link" {
  description = "Fully-qualified self link of the VPC network."
  value       = data.google_compute_network.olh.self_link
}

output "subnetwork_name" {
  description = "Regional subnetwork hosting the agent VM and the cluster MIG."
  value       = data.google_compute_subnetwork.olh.name
}

output "subnetwork_cidr" {
  description = "Primary CIDR range of the subnetwork."
  value       = data.google_compute_subnetwork.olh.ip_cidr_range
}

output "private_google_access" {
  description = "Whether Private Google Access is enabled on the subnetwork - an OLH prerequisite."
  value       = data.google_compute_subnetwork.olh.private_ip_google_access
}

output "firewall_rule" {
  description = "Firewall rule permitting intra-cluster traffic."
  value       = var.firewall_rule_name
}

output "kms_key_id" {
  description = "Cloud KMS key ID used as the CMEK for lakehouse data."
  value       = var.kms_key_id
}

output "mgmt_service_account_email" {
  description = "Service account QTC impersonates to manage resources."
  value       = var.mgmt_service_account_email
}

output "node_service_account_email" {
  description = "Service account attached to the agent VM and cluster nodes."
  value       = var.node_service_account_email
}

output "gcs_table_bucket" {
  description = "Iceberg table storage bucket."
  value       = data.google_storage_bucket.table.name
}

output "gcs_landing_bucket" {
  description = "Landing bucket."
  value       = data.google_storage_bucket.landing.name
}

output "gcs_config_bucket" {
  description = "Config bucket."
  value       = data.google_storage_bucket.config.name
}

output "biglake_catalog" {
  description = "BigLake catalog backing the Iceberg tables (Qlik: Google Lakehouse Runtime Catalog)."
  value       = google_biglake_catalog.olh.name
}

output "biglake_database" {
  description = "BigLake database created for OLH."
  value       = google_biglake_database.olh.name
}

output "bigquery_mirror_dataset" {
  description = "BigQuery dataset that zero-copy mirroring writes into. GCP-only OLH feature."
  value       = google_bigquery_dataset.mirror.dataset_id
}

output "workload_identity_pool" {
  description = "Workload Identity pool QTC federates through, or null when qtc_auth_method is preauthorized_sa."
  value       = local.use_wif ? google_iam_workload_identity_pool.qtc[0].name : null
}

output "workload_identity_provider" {
  description = "Workload Identity provider resource name QTC presents its OIDC token to."
  value       = local.use_wif ? google_iam_workload_identity_pool_provider.qtc[0].name : null
}

output "secret_prefix" {
  description = "Secret Manager name prefix holding the QTC integration values."
  value       = local.secret_prefix
}

output "qtc_summary" {
  description = "Single object containing every value QTC needs - copy/paste friendly."
  value = {
    gcp_project_id             = data.google_project.current.project_id
    gcp_project_number         = data.google_project.current.number
    gcp_region                 = var.gcp_region
    gcp_zones                  = var.gcp_zones
    network_name               = data.google_compute_network.olh.name
    subnetwork_name            = data.google_compute_subnetwork.olh.name
    subnetwork_cidr            = data.google_compute_subnetwork.olh.ip_cidr_range
    private_google_access      = data.google_compute_subnetwork.olh.private_ip_google_access
    firewall_rule              = var.firewall_rule_name
    kms_key_id                 = var.kms_key_id
    mgmt_service_account_email = var.mgmt_service_account_email
    node_service_account_email = var.node_service_account_email
    gcs_table_bucket           = data.google_storage_bucket.table.name
    gcs_landing_bucket         = data.google_storage_bucket.landing.name
    gcs_config_bucket          = data.google_storage_bucket.config.name
    biglake_catalog            = google_biglake_catalog.olh.name
    biglake_database           = google_biglake_database.olh.name
    bigquery_mirror_dataset    = google_bigquery_dataset.mirror.dataset_id
    workload_identity_provider = local.use_wif ? google_iam_workload_identity_pool_provider.qtc[0].name : null
    secret_prefix              = local.secret_prefix
  }
}
