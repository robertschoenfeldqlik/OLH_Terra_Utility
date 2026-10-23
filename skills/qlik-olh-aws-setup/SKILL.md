---
name: qlik-olh-aws-setup
description: Stand up Qlik Open Lakehouse (OLH) on AWS end to end - build the prerequisites (VPC, two public subnets in two AZs, security group, S3 gateway endpoint, KMS key, management role with Qlik's trust entity, EC2 instance profile, S3 buckets), attach the Qlik-generated role policies, pre-create the service-linked roles that break first deploys, emit the Qlik Cloud network-integration import JSON plus the form values, import them, and verify Connected/Running. Use whenever someone wants to set up, provision, deploy, rebuild or troubleshoot an OLH network integration or lakehouse cluster on AWS; mentions the Qlik "Create AWS network integration" form, "Import configuration"/"Export form", a Qlik trust entity or ExternalId, qlik-proxy-assume-role, or the OLH management role / EC2 instance profile; or hits "Failed to deploy cluster in AWS" or "Service-Linked Role ... not yet ready" - even if they never say "skill".
---

# Qlik Open Lakehouse on AWS

Takes an empty (or partly built) AWS account to a **Connected** network
integration and a **Running** lakehouse cluster in Qlik Cloud, and leaves behind
two files the user keeps: the import JSON and the form values.

Everything below was proven against a live tenant and account. Where Qlik's own
docs are silent (the import file, the generated policies, the service-linked role
race), the references hold what was observed.

## What you need from the user

| Input | Where it comes from |
|---|---|
| Name prefix, e.g. `rgs-olh-mcg` | the user; also used as the `Workload` tag |
| Owner initials, environment label | the user |
| AWS region | the user (subnets go in two of its AZs) |
| AWS access | the AWS MCP connector (preferred) or local boto3 credentials |
| **Trust entity** — Qlik proxy role ARN + `sts:ExternalId` | Qlik form > section 1 > Management role > **Configuration guide**. Users often save it as a `trust entity.txt`; read it, don't retype it |
| Qlik tenant host, integration space name | the user |
| **Cluster type — CDC or Streaming?** | always ask; never assume. CDC = database/SaaS change capture, billed by data volume, tasks free. Streaming = streaming ingestion/transformation and Qlik Replicate sources, billed by compute |

Ask once for anything missing. Confirm the AWS account before creating anything:
call `sts GetCallerIdentity` and say which account (and whether it is root) you
are about to build in.

## Workflow

### 1. Write the config
Copy `scripts/config.example.json` and fill it. Keep sizing small unless told
otherwise: `extra_buckets: ["iceberg","landing"]`, `create_kinesis: false` —
the integration form asks for neither; they serve later pipeline work.

### 2. Plan, then build — `scripts/olh_core.py`
Run `plan` first (read-only) and show the user what would be created. Then
`build`. Every step looks up by name/tag first, so a re-run never duplicates.

- **AWS MCP:** pass the full contents of `olh_core.py` (not `olh_build.py` — the
  sandbox statically rejects its boto3/argparse/getattr code) to
  `aws___run_script`, followed by
  ```python
  CFG = { ... }                              # the config as a dict
  result = await run(CFG, call_boto3, "plan")   # then "build"
  result
  ```
- **Local:** `python scripts/olh_build.py config.json --mode build --out outputs.json`

Build creates, in order: the two service-linked roles, VPC + IGW + public route
table, two public subnets (auto-assign public IP, routed to the IGW), the
security group (all TCP from the VPC CIDR), the S3 gateway endpoint, a KMS CMK
with rotation, the management role (trust = trust entity, verbatim), the node
role + `AmazonSSMManagedInstanceCore` + instance profile, the buckets
(CMK-encrypted, public access blocked), and the two Qlik inline policies.
Everything is tagged `Name, Owner, Environment, Workload=<prefix>,
Application=open-lakehouse, CreateDate, ManagedBy`.

Why the service-linked roles come first: on a fresh account Qlik creates
`AWSServiceRoleForAutoScaling` itself and then fails before it is usable. See
`references/troubleshooting.md`.

Save `result["outputs"]` to `outputs.json` — the emitter needs it.

### 3. Verify the AWS side — `--mode verify`
Re-reads every object by id: tags, public subnets, IGW and endpoint routes, CMK
on every bucket, trust policy equal to the trust entity, both inline policies
equal to the Qlik-generated ones, both service-linked roles present. Report any
row with `ok: false`; don't go to Qlik with a red row.

### 4. Resolve the space id
The import JSON needs the space **id**. From a browser signed in to the tenant:
`GET https://<tenant>/api/v1/spaces?name=<url-encoded name>` → `data[0].id`.
Put it in the config as `space_id` (and `space_name` for the form sheet).

### 5. Emit the import file and the form values — `scripts/olh_emit.py`
```
python scripts/olh_emit.py config.json outputs.json --dir <output folder>
```
Writes `<name>_AWS_import.json` (same keys and order as Qlik's own Export form)
and `<name>_form_values.md` (same values in the form's section order). Hand
both to the user. `assets/example-import.json` shows the exact shape.

### 6. Create the integration in Qlik Cloud
Administration > Lakehouse clusters > Network integrations > **Create network
integration** ▾ > **Import configuration** > load the JSON. Check both Space
fields (a missing space id silently becomes Default_Data_Space) and that the
integration name is unique in the tenant, then **Confirm**. Confirm launches billable EC2 in the user's account — get a
clear yes for it.

If filling by hand instead, `<name>_form_values.md` has every field.
`references/qtc-form-and-import.md` maps each form label to its JSON key and
covers the quirks (AZ is a letter; "EC2 instances profile" wants the profile
ARN, not the role ARN).

### 7. Verify it is live
Poll until the integration is **Connected** and the cluster **Running**
(typically 2–4 minutes):
`GET /api/v1/network-integrations` and `GET /api/v1/lakehouse-clusters` (bare
arrays; check `status` / `statusReason`), or the two tabs in the UI. In AWS you
should see two `qlik_<uuid>` Auto Scaling groups: a `GatewayCluster`
(r8i-flex.xlarge, on-demand) and a `LakehouseCluster` (r8a.2xlarge, Spot).
The form has no size control; that pair is the floor — tell the user, since
it is a running cost.

Call it done only when the user sees Connected and Running in the Qlik UI.

## Adding a cluster to an existing integration
One integration can carry several clusters — for example a CDC cluster from the
import plus a Streaming one. This is a different dialog from the integration
form: Administration > Lakehouse clusters > **Lakehouse clusters** tab >
**Create new** > *Create lakehouse cluster*.

Ask CDC or Streaming first. Name and tag it by appending the capability to the
user's naming — e.g. `rgs_olh_mcg_streaming` — and use the same value for the
`Name` and `Workload` tags. Then fill, smallest by default unless told otherwise:

| Field | Smallest setting | Why |
|---|---|---|
| Network integration | the existing one | |
| Space | the user's space (it defaults to Default_Data_Space) | |
| Cluster capabilities | CDC workloads / Streaming workloads | as answered |
| Family type > Type / Size | `r` / `2xlarge` | lists fill only after the integration is picked: Type `r`/`x`, Size `2xlarge` up to `96xlarge`/metal. `r`+`2xlarge` is the smallest; Qlik launched it as r8i-flex.2xlarge Spot |
| AWS On-Demand Instances | `0` | |
| AWS Spot Instances Min / Max | `1` / `1` | one instance is the floor for a working cluster |
| Scaling strategy | Low cost | default is Low latency |
| Tags | `Name`, `Workload` = the cluster name | |

The Space box is type-to-search: type part of the name, then ArrowDown +
Enter — clicking the option can leave it empty and keep **Create** disabled.
Then **Create** and verify as in step 7: the new cluster reaches **Running**
(about 1–2 minutes), and AWS shows another `qlik_<uuid>` Auto Scaling group.

## When something fails
Read `references/troubleshooting.md`. The common one — *"Service-Linked Role for
this Auto Scaling group is not yet ready"* — is fixed by confirming the role
exists, then **⋯ > Redeploy** on the integration row.

## Scope
AWS only. The GCP Private Preview uses a different form and has not been
captured. In the import JSON, `cluster_capability` takes `cdc` (`"database"`) or
`streaming` (`"streaming"`); only Early rollout is a confirmed rollout value, and
`olh_emit.py` stops rather than guessing others (see the reference).
