# Qlik Open Lakehouse — AWS Deployment Utility

A wizard-driven provisioning tool for the AWS resources Qlik Talend Cloud's Open
Lakehouse (OLH) needs. Two flavors share the same flow: tool checks, AWS
authentication, resource discovery, AWS-CLI provisioning of the heavy
resources, and a Terraform layer that adds the auxiliary objects QTC requires.

## Quick start

### Windows
```cmd
run_qlik_deploy_gui.bat
```
Self-elevates to admin (required for the AWS CLI MSI install path) and launches
the PowerShell GUI wizard.

### Linux / macOS
```bash
chmod +x qlik_deploy_olh.sh
./qlik_deploy_olh.sh
```

## What's in this repo

| File | Purpose |
|---|---|
| `qlik_deploy_olh_gui.ps1` | Windows GUI wizard (PowerShell + WinForms) |
| `qlik_deploy_olh.sh` | Linux / macOS terminal wizard |
| `run_qlik_deploy_gui.bat` | Self-elevating launcher for the GUI |
| `parse_check.ps1` | Quick syntax check for the GUI script |
| `versions.tf` | Terraform + AWS provider pins, S3 backend |
| `providers.tf` | AWS provider with `default_tags` |
| `variables.tf` | Variables consumed from `terraform.tfvars` (with validation) |
| `main.tf` | Data sources for AWS-CLI resources + Glue DB + SSM parameters |
| `outputs.tf` | QTC integration values (incl. `qtc_summary` object) |
| `Qlik-OLH-Deployment-Instructions.docx` | Full instruction document (Qlik branded) |

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| AWS CLI v2 | latest | Wizard auto-installs from `awscli.amazonaws.com` |
| Terraform | ≥ 1.5.0 | Wizard fetches latest from HashiCorp's releases API |
| AWS provider | ≥ 5.80 | Pulled by `terraform init` (v6.43+ today) |
| Python 3 | any | Bash wizard only |
| PowerShell | 5.1+ | Windows GUI |

The wizard checks installed versions against the latest release and offers an
in-place upgrade if you're behind.

## Terraform layer

The wizard provisions the heavy AWS resources (Security Group, KMS, IAM, S3,
Kinesis) via the AWS CLI. Terraform then takes over for state, drift detection,
and the auxiliary layer:

- **Data sources** — read-only references to the AWS-CLI-created resources
- **Account sanity check** — fails fast if creds don't match `aws_account_id`
- **Glue Catalog database** — `<initials>_<workload>_<env>_db_glue`
- **SSM Parameter Store** — 9 parameters under `/<initials>/<workload>/<env>/`

After applying, copy the QTC integration values straight from Terraform:
```bash
terraform output qtc_summary
```

## Verifying offline

```bash
terraform fmt -check
terraform init -backend=false
terraform validate
```

Confirmed against Terraform v1.14.6 + AWS provider v6.43.0.

## Documentation

`Qlik-OLH-Deployment-Instructions.docx` has the full step-by-step guide,
inputs reference, output-file descriptions, the Terraform flow, and a
troubleshooting table. Open it in Word for the branded version.

## License

Internal use within Qlik. Contact the OLH deployment lead before sharing.
