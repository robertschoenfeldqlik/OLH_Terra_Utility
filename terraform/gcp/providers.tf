provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region

  # GCP labels are stricter than AWS tags: lowercase letters, digits, dashes
  # and underscores only, so these keys are lowercased versions of the AWS tag
  # set rather than a straight copy.
  default_labels = {
    owner       = var.tag_owner
    environment = var.tag_env
    workload    = var.tag_workload
    application = "open-lakehouse"
    createdate  = var.tag_createdate
    managedby   = "terraform"
  }
}
