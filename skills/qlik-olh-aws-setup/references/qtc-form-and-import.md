# Qlik Cloud "Create AWS network integration" — form, import file, API

Everything here was read off a live tenant on 2026-10-22, not from documentation
(help.qlik.com does not describe the import file at all). Qlik can change the
form; when in doubt, open it, fill it, and click **Export form** — that file is
the ground truth for the import schema.

## Where it lives

Administration > **Lakehouse clusters** > **Network integrations** tab >
**Create network integration** ▾ > *Create new configuration* | *Import configuration*.
Route: `https://<tenant>/admin/lakehouse-clusters/network-integrations`.

The form footer has **Cancel · Export form · Confirm**. Export form downloads the
current values as `<name>_AWS_<timestamp>.json`; Import configuration loads that
same shape back.

## Field ↔ JSON key map

| Form section | Form label | Import JSON key | Notes |
|---|---|---|---|
| Details | Network integration name | `networkIntegrationName` | |
| Details | Integration space | `spaceId` | space **id**, not name |
| 1 Grant Qlik access | AWS account | `awsAccount` | 12 digits |
| 1 | Symmetric KMS key ARN | `symmetricKmsKey` | full ARN |
| 1 | S3 bucket for internal Qlik files | `bucketName` | name only, no `s3://`; this is the **config** bucket, and the EC2 policy is scoped to it |
| 1 | Management role | `defaultManagementRole` | role ARN |
| 1 | EC2 instances profile | `defaultDataAccessRole` | **instance-profile** ARN, not the role ARN |
| 2 Connect Qlik to your network | Region | `region` | |
| 2 | VPC ID | `vpcId` | form validates "must start with vpc-", 8 or 17 hex |
| 2 | Availability Zone + Subnet (rows, *Add*) | `subnetIds: [{availabilityZone, subnet}]` | AZ is the **letter only** (`"a"`), one row per AZ |
| 2 | Security groups (*Add*) | `securityGroupIds: [{securityGroupId}]` | |
| 2 | EC2 key pair name (optional) | `keyPairName` | `null` = None |
| 2 | Advanced settings > Use a proxy server | `useProxy` | |
| 3 Create a lakehouse cluster | Cluster name | `clusterName` | |
| 3 | Space | `clusterSpaceId` | |
| 3 | Cluster capabilities | `clusterCapabilities` | **CDC workloads = `"database"`** (confirmed). Streaming workloads: value not yet observed |
| 3 | Tags (key/value, *Add*) | `tags: [{key, value}]` | applied to the cluster's EC2 instances |
| 3 | Custom image | `useCustomImage` | |
| 3 | Rollout phase | `rolloutPhaseType` | **Early rollout = `"early-rollout"`** (confirmed). Later rollout: value not yet observed |
| — | (implicit) | `providerType` | `"aws"` |

`olh_emit.py` only maps the confirmed enum values. To use Streaming or Later
rollout, export the form once with that option selected, read the value, and
pass it as `cluster_capability_raw` / `rollout_raw` in the config.

There is **no** field for Kinesis, the ExternalId, a Glue database, or the
iceberg/landing buckets. The ExternalId lives only in the management role's trust
policy; the data buckets are used later by pipeline projects.

## The trust entity and the generated policies

Each role field has a **Configuration guide** link. The Management role guide
shows the *Trusted entity* — Qlik's proxy principal
(`arn:aws:iam::338144066592:role/qlik-proxy-assume-role` on the tenant tested)
plus an `sts:ExternalId` unique to the tenant — and an inline policy. The EC2
instance profile guide shows a second inline policy. Both policies are
**generated from the values already typed into section 1** (account, KMS key,
bucket), which is why `olh_build.py` templates them from the build outputs
instead of storing literal copies. The ExternalId appears in both: the trust
policy and the EC2 policy's `sts:AssumeRole` statement.

## Spaces

`GET https://<tenant>/api/v1/spaces?name=<url-encoded name>` returns
`{"data": [{"id", "name", "type"}]}`. Run it from a browser tab already signed in
to the tenant (or with an API key as a bearer token).

## Status API (for verification)

Both return a bare JSON **array**, newest first:

- `GET /api/v1/network-integrations?sort=-creationTime` → items with `id`, `name`,
  `region`, `status`, `statusReason`, `provider{…}`. Healthy = `"Connected"`.
- `GET /api/v1/lakehouse-clusters?sort=-creationTime` → items with `id`, `name`,
  `status`, `statusReason`, `releaseVersion`,
  `deploymentConfig.networkIntegrationId`. Healthy = `"Running"`.

UI statuses seen: integration *Deploying → Connecting → Connected* (or *Failed*);
cluster *Connecting → Running*.

## What Qlik builds in your account after Confirm

Two Auto Scaling groups named `qlik_<uuid>` (min = max = desired = 1) with
`qlik_*` launch templates:

| Role (tag `qlik_cluster_type`) | Instance seen | Purchase |
|---|---|---|
| `GatewayCluster` — the network integration agent | r8i-flex.xlarge | on-demand |
| `LakehouseCluster` — the cluster | r8a.2xlarge | Spot |

The form exposes no instance-size setting; this pair is the floor. Instances
carry your cluster tags plus `qlik_cluster`, `qlik_cluster_id`,
`qlik_network_integration_id`, `qlik_tenant_hostname`.
