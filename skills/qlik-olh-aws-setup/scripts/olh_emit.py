"""
Emit the Qlik Cloud network-integration import file and the matching form values.

    python olh_emit.py config.json outputs.json [--dir OUT_DIR]

config.json   the same config used for olh_build.py, plus the Qlik Cloud fields
outputs.json  the "outputs" written by `olh_build.py --mode build --out ...`
              (the whole build result or just its "outputs" object both work)

Writes two files:
  <integration_name>_AWS_import.json   load via Administration > Lakehouse clusters >
                                       Network integrations > Create network integration >
                                       Import configuration
  <integration_name>_form_values.md    the same values in the form's own section order,
                                       for filling the form by hand or checking an import

The JSON keys and their order match the file Qlik's own "Export form" button
writes (captured 2026-10-22). Only enum values seen in a real export are mapped;
anything else must be passed raw - see references/qtc-form-and-import.md.
"""
import argparse
import json
import os
import sys

# "database" was read from a real Export form file. "streaming" is the value the
# form's radio button and the lakehouse-clusters API (clusterCapabilities.type)
# use for Streaming workloads, which is exactly how "database" maps for CDC
# (verified on a live streaming cluster, 2026-10-22). Later rollout has not been
# observed - pass it raw with rollout_raw once confirmed.
CAPABILITY = {"cdc": "database", "streaming": "streaming"}
ROLLOUT = {"early": "early-rollout"}


def build_import(cfg, out):
    def need(key, src, where):
        if not src.get(key):
            sys.exit(f"missing {key} in {where}")
        return src[key]

    capability = cfg.get("cluster_capability_raw") or CAPABILITY.get(cfg.get("cluster_capability", "cdc"))
    if not capability:
        sys.exit(f"cluster_capability {cfg.get('cluster_capability')!r} has no confirmed import value; "
                 "export the form once with it selected and pass the value as cluster_capability_raw")
    rollout = cfg.get("rollout_raw") or ROLLOUT.get(cfg.get("rollout", "early"))
    if not rollout:
        sys.exit(f"rollout {cfg.get('rollout')!r} has no confirmed import value; "
                 "export the form once with it selected and pass the value as rollout_raw")

    space = need("space_id", cfg, "config (resolve it with GET /api/v1/spaces?name=<space name>)")
    prefix = cfg["prefix"]
    tags = cfg.get("cluster_tags") or {"Name": f"{prefix}-cluster", "Workload": prefix}

    return {
        "providerType": "aws",
        "networkIntegrationName": cfg.get("integration_name", prefix),
        "spaceId": space,
        "awsAccount": need("account_id", out, "outputs"),
        "symmetricKmsKey": need("kms_key_arn", out, "outputs"),
        "bucketName": need("buckets", out, "outputs")["config"],
        "defaultManagementRole": need("mgmt_role_arn", out, "outputs"),
        # The form labels this "EC2 instances profile" and wants the PROFILE ARN, not the role ARN.
        "defaultDataAccessRole": need("instance_profile_arn", out, "outputs"),
        "region": need("region", out, "outputs"),
        "vpcId": need("vpc_id", out, "outputs"),
        "keyPairName": cfg.get("key_pair_name"),
        "useProxy": False,
        "clusterName": cfg.get("cluster_name", f"{prefix}-cluster"),
        "clusterSpaceId": cfg.get("cluster_space_id", space),
        "clusterCapabilities": capability,
        "useCustomImage": False,
        "rolloutPhaseType": rollout,
        # The form's Availability Zone dropdown holds only the zone letter.
        "subnetIds": [{"availabilityZone": s["az"][-1], "subnet": s["subnet_id"]} for s in need("subnets", out, "outputs")],
        "securityGroupIds": [{"securityGroupId": need("security_group_id", out, "outputs")}],
        "tags": [{"key": k, "value": v} for k, v in tags.items()],
    }


def build_form_md(cfg, imp, space_name):
    cap = {"database": "CDC workloads", "streaming": "Streaming workloads"}.get(imp["clusterCapabilities"], imp["clusterCapabilities"])
    roll = {"early-rollout": "Early rollout"}.get(imp["rolloutPhaseType"], imp["rolloutPhaseType"])
    az_rows = "\n".join(f"| {s['availabilityZone']} | `{s['subnet']}` |" for s in imp["subnetIds"])
    tag_rows = "\n".join(f"| {t['key']} | {t['value']} |" for t in imp["tags"])
    return f"""# {imp['networkIntegrationName']} - Create AWS network integration

Tenant: `{cfg.get('tenant', '<tenant>')}` > Administration > Lakehouse clusters > Network integrations >
Create network integration > **Import configuration** (load `{imp['networkIntegrationName']}_AWS_import.json`)
or **Create new configuration** and enter the values below.

## Details
| Field | Value |
|---|---|
| Network integration name | `{imp['networkIntegrationName']}` |
| Integration space | {space_name} (`{imp['spaceId']}`) |

## 1. Grant Qlik access to your cloud
| Field | Value |
|---|---|
| AWS account | `{imp['awsAccount']}` |
| Symmetric KMS key ARN | `{imp['symmetricKmsKey']}` |
| S3 bucket for internal Qlik files | `{imp['bucketName']}` |
| Management role | `{imp['defaultManagementRole']}` |
| EC2 instances profile | `{imp['defaultDataAccessRole']}` |

The two "Configuration guide" links on this section generate the role policies.
The build already attached them (`qlik-olh-management`, `qlik-olh-ec2-instance`);
`olh_build.py --mode verify` confirms they still match.

## 2. Connect Qlik to your network
| Field | Value |
|---|---|
| Region | `{imp['region']}` |
| VPC ID | `{imp['vpcId']}` |
| Security groups | `{imp['securityGroupIds'][0]['securityGroupId']}` |
| EC2 key pair name | {imp['keyPairName'] or 'None'} |
| Advanced settings > Use a proxy server | off |

| Availability Zone | Subnet |
|---|---|
{az_rows}

## 3. Create a lakehouse cluster
| Field | Value |
|---|---|
| Cluster name | `{imp['clusterName']}` |
| Space | {space_name} (`{imp['clusterSpaceId']}`) |
| Cluster capabilities | {cap} |
| Custom image | off |
| Rollout phase | {roll} |

| Tag key | Tag value |
|---|---|
{tag_rows}
"""


def main():
    ap = argparse.ArgumentParser(description="Emit the QTC import JSON and form values")
    ap.add_argument("config")
    ap.add_argument("outputs")
    ap.add_argument("--dir", default=".")
    a = ap.parse_args()
    with open(a.config, encoding="utf-8") as f:
        cfg = json.load(f)
    with open(a.outputs, encoding="utf-8") as f:
        out = json.load(f)
    out = out.get("outputs", out)

    imp = build_import(cfg, out)
    os.makedirs(a.dir, exist_ok=True)
    base = os.path.join(a.dir, imp["networkIntegrationName"])
    with open(base + "_AWS_import.json", "w", encoding="utf-8") as f:
        f.write(json.dumps(imp, indent=2) + "\n")
    with open(base + "_form_values.md", "w", encoding="utf-8") as f:
        f.write(build_form_md(cfg, imp, cfg.get("space_name", "")))
    print(base + "_AWS_import.json")
    print(base + "_form_values.md")


if __name__ == "__main__":
    main()
