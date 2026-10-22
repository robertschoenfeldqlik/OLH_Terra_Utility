# Qlik Open Lakehouse — Deployment Utility (AWS + Google Cloud)

A wizard-driven provisioning tool for the cloud resources Qlik Talend Cloud's
Open Lakehouse (OLH) needs. Two flavors share the same flow: tool checks, cloud
authentication, resource discovery, CLI provisioning of the heavy resources, and
a Terraform layer that adds the auxiliary objects and asserts the prerequisites
QTC depends on.

| Cloud | OLH status | What the wizard provisions |
|---|---|---|
| **AWS** | GA | VPC · subnets · security group · KMS · 2 IAM roles · instance profile · S3 × 4 · Kinesis |
| **Google Cloud** | **Private Preview** (opened 2 Sep 2026, GA planned Q4 2026) | VPC network · subnetwork · Cloud NAT · firewall · Cloud KMS · 2 service accounts · GCS × 4 |

> **Google Cloud is in Private Preview.** Your tenant must be enrolled before a
> lakehouse cluster can be created. Preview scope is **CDC and SaaS sources
> only** — streaming (Kafka/GCS) and Qlik Replicate sources arrive later in the
> preview, which is why the GCP path provisions no stream resource where AWS
> creates a Kinesis stream. Zero-copy mirroring into **BigQuery** is a Google
> Cloud–only feature with no AWS equivalent.

## Quick start

### Windows

```cmd
run_qlik_deploy_gui.bat
```

Self-elevates to admin (required for the AWS CLI MSI install path) and launches
the PowerShell GUI wizard. Pick the target cloud on the Welcome step.

### Linux / macOS

```bash
chmod +x qlik_deploy_olh.sh
./qlik_deploy_olh.sh
```

The wizard asks which cloud to target. To skip the prompt:

```bash
./qlik_deploy_olh.sh --gcp
```

Other flags: `--dry-run`, `--drift`, `--teardown` (the last two are AWS-only),
`--cloud=aws|gcp`, `--help`.

## What's in this repo

| File | Purpose |
|---|---|
| `qlik_deploy_olh_gui.ps1` | Windows GUI wizard (PowerShell + WinForms), both clouds |
| `qlik_deploy_olh.sh` | Linux / macOS terminal wizard, both clouds |
| `run_qlik_deploy_gui.bat` | Self-elevating launcher for the GUI |
| `parse_check.ps1` | Quick syntax check for the GUI script |
| `terraform/aws/` | Terraform root module for AWS (S3 backend) |
| `terraform/gcp/` | Terraform root module for Google Cloud (GCS backend) |
| `skills/qlik-olh-aws-setup/` | Portable Claude skill: builds the AWS side and emits the Qlik Cloud import JSON (see below) |
| `skills/qlik-olh-aws-setup.skill` | The same skill, packaged for one-click install |
| `Qlik-OLH-Deployment-Instructions.docx` | Full instruction document (Qlik branded) |

The two Terraform layers are separate root modules rather than one module with a
switch: Terraform permits only one `backend` block per configuration, and AWS
needs `s3` while Google Cloud needs `gcs`.

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| AWS CLI v2 | latest | AWS path only. Auto-installs from `awscli.amazonaws.com`; outdated detection via GitHub tags API |
| Google Cloud CLI | latest | GCP path only. Auto-installs from `dl.google.com`; staleness via `gcloud components list` |
| Terraform | ≥ 1.10.0 | Wizard fetches latest from HashiCorp's releases API |
| AWS provider | ≥ 5.80 | Pulled by `terraform init` (v6.65 today) |
| Google provider | ≥ 6.0 | Pulled by `terraform init` |
| Python 3 | any | Bash wizard only; auto-detects `python3` / `python` / `py` |
| PowerShell | 5.1+ | Windows GUI (launcher self-elevates for MSI install) |

The Terraform floor is 1.10.0 because the AWS backend uses S3-native state
locking (`use_lockfile = true`), which needs no DynamoDB table. Provider versions
are pinned by the committed `.terraform.lock.hcl` in each module.

### Google Cloud credentials

`gcloud auth login` and Application Default Credentials are **separate credential
stores**. The Terraform Google provider reads ADC, so both wizards check for it
and offer to run `gcloud auth application-default login`. Skipping that step
produces an authentication failure at `terraform plan`, not at wizard time.

## Terraform layer

The wizard provisions the heavy resources via the cloud CLI. Terraform then
takes over for state, drift detection, prerequisite assertions, and the
auxiliary layer.

### AWS — `terraform/aws/`

- **Data sources** — read-only references to the CLI-created resources
- **Assertions** (fail at plan time, before anything is created):
  - credentials match `aws_account_id`
  - the management role's trust policy names the Qlik principal and requires your
    `sts:ExternalId` under an `Allow` statement's `sts:ExternalId` condition (not
    just anywhere in the document)
  - at least two subnets, across two AZs, each auto-assigning public IPs and
    routed to an Internet Gateway (explicit association or the VPC main table)
  - `vpc_cidr` matches the live VPC
- **Creates** — Glue Catalog database, S3 gateway VPC endpoint, the node role's
  S3/Kinesis/KMS/Glue policy, and 15 SSM parameters under `/<initials>/<workload>/<env>/`

### Google Cloud — `terraform/gcp/`

- **Data sources** — network, subnetwork, Cloud KMS key, both service accounts, buckets
- **Assertions**:
  - credentials match `gcp_project_id` and `gcp_project_number`
  - Private Google Access is on (the counterpart of the S3 gateway endpoint)
  - every zone is inside the configured region, and there are at least two
  - the management and node service accounts are different identities
- **Creates** — BigLake catalog + database (Qlik calls this the *Google Lakehouse
  Runtime Catalog*), a CMEK-encrypted BigQuery dataset for zero-copy mirroring,
  the node service account's data-plane grants, Workload Identity Federation for
  the QTC tenant, and 15 Secret Manager entries

After applying, copy the QTC integration values straight from Terraform:

```bash
terraform -chdir=terraform/aws output qtc_summary
```

## Qlik Cloud side — the network integration (AWS)

The live **Create AWS network integration** form (Administration > Lakehouse
clusters) asks for less than this repo builds: account, KMS key ARN, **one**
"S3 bucket for internal Qlik files" (the config bucket), the management role
ARN, the EC2 **instance-profile** ARN, region, VPC, AZ+subnet pairs, security
group, and the cluster's name/space/capability/tags. There is no Kinesis,
ExternalId, Glue or SSM field. Its **Export form** / **Import configuration**
buttons round-trip a JSON file whose schema is documented in
`skills/qlik-olh-aws-setup/references/qtc-form-and-import.md`.

`skills/qlik-olh-aws-setup/` turns that into a repeatable flow, verified end to
end against a live account and tenant on 2026-10-22: build the AWS objects
(through the AWS MCP connector or local boto3), attach the policies the form's
*Configuration guide* generates, pre-create the Auto Scaling and Spot
service-linked roles, then emit `<name>_AWS_import.json` plus the form values.
Install it from `skills/qlik-olh-aws-setup.skill`.

On a fresh account the first deploy fails with *"The Service-Linked Role for
this Auto Scaling group is not yet ready for use"*: Qlik creates the role and
uses it in the same breath. The skill creates both roles up front; after the
fact, **⋯ > Redeploy** on the integration recovers it.

The wizards' `qlik-network-integration.txt` reference sheet still lists the
older, broader value set; use the skill's emitted form values for the Qlik
form itself.

## Service mapping

| AWS | Google Cloud |
|---|---|
| EC2 agent + EC2 cluster | GCE VM + GCE MIG (Spot VMs) |
| VPC + 2 public subnets in 2 AZs | VPC network + regional subnetwork, MIG across 2 zones |
| Security group (inbound all TCP from VPC CIDR) | Firewall rule (ingress from subnetwork CIDR); egress is allowed by GCP's implied default rule |
| S3 gateway VPC endpoint | Private Google Access on the subnetwork |
| Internet Gateway | Cloud Router + Cloud NAT |
| KMS CMK | Cloud KMS symmetric CMEK |
| S3 iceberg / landing / config | GCS table storage / landing / config |
| Kinesis Data Stream | *(nothing at launch — CDC and SaaS only)* |
| IAM management role + `sts:ExternalId` | Management service account + Workload Identity Federation |
| EC2 instance profile role | Node service account |
| AWS Glue Data Catalog | Google Lakehouse Runtime Catalog (BigLake) |
| SSM Parameter Store | Secret Manager |
| *(no equivalent)* | BigQuery zero-copy mirror dataset |

## Known gap: the QTC authentication model on Google Cloud

Qlik has **not published** how QTC authenticates into a customer's GCP project
for the Private Preview. The GCP module assumes **Workload Identity Federation**,
the GCP counterpart of the assume-role-with-ExternalId pattern OLH uses on AWS,
with your tenant ID as the allowed audience. This is a reasoned assumption, not
a documented requirement.

It is isolated: set `qtc_auth_method = "preauthorized_sa"` to skip the pool
entirely, or change only the *Qlik Talend Cloud tenant binding* section of
`terraform/gcp/main.tf` if the preview onboarding pack specifies something else.
Confirm with Product Management (PM: Antoine Richard) before a customer
deployment.

## Verifying offline

```bash
terraform -chdir=terraform/aws fmt -check && terraform -chdir=terraform/aws validate
```

```bash
terraform -chdir=terraform/gcp fmt -check && terraform -chdir=terraform/gcp validate
```

Both need a one-off `terraform -chdir=terraform/<cloud> init -backend=false`
first. Confirmed against Terraform v1.15.0 with AWS provider v6.65.0 and Google
provider v8.3.0.

Syntax checks for the wizards:

```bash
bash -n qlik_deploy_olh.sh
```

```powershell
./parse_check.ps1
```

## Secrets

`terraform.tfvars` holds your QTC ExternalId (AWS) or tenant ID (GCP). Both are
written under `terraform/<cloud>/` and are covered by `.gitignore`. Don't commit
them.

## Documentation

`Qlik-OLH-Deployment-Instructions.docx` has the full step-by-step guide, inputs
reference, output-file descriptions, the Terraform flow, and a troubleshooting
table. Open it in Word for the branded version.

## License

Internal use within Qlik. Contact the OLH deployment lead before sharing.
