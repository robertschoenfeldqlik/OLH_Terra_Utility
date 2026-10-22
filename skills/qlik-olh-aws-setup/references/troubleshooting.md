# Troubleshooting

## "Failed to deploy cluster in AWS. Error: The Service-Linked Role for this Auto Scaling group is not yet ready for use."

**Cause.** A fresh AWS account has no `AWSServiceRoleForAutoScaling`. Qlik's
management role creates it on first deploy (`iam:CreateServiceLinkedRole`), but
creates the Auto Scaling group in the same breath, before the new role is usable.
Seen 2026-10-22: role created at 22:57:03 UTC, deploy failed at 22:57.

**Prevention.** `olh_build.py --mode build` creates `AWSServiceRoleForAutoScaling`
and `AWSServiceRoleForEC2Spot` before you ever press Confirm. The Spot one has the
same race for the Spot cluster instance.

**Fix after the fact.**
1. Confirm the role now exists: `iam GetRole AWSServiceRoleForAutoScaling` (and
   `AWSServiceRoleForEC2Spot`; create it with `CreateServiceLinkedRole
   AWSServiceName=spot.amazonaws.com` if missing).
2. Network integrations row > **⋯** > **Redeploy**. The menu offers *Redeploy*
   and *Retry configuration update* while the integration is Failed; Redeploy is
   the one that relaunches the agent. No dialog or toast appears — the status
   flips from Failed to Connecting and the error message clears.
3. Wait for Connected (agent) and Running (cluster), about 2–4 minutes.

Before redeploying, the cluster may already show Connecting with its Spot
instance running — Qlik retries the cluster on its own, but not the gateway
agent, and the cluster cannot finish connecting without the agent.

## The deploy fails with an access-denied style error

The two inline policies must match what the form's **Configuration guide** links
show *for the values you entered*. Run `olh_build.py --mode verify`: it re-derives
both policies and compares them with what is attached. If Qlik has changed its
generated policy, open each guide, copy the JSON, and update
`mgmt_inline_policy` / `node_inline_policy` in `olh_core.py` — keep the
parameters (account, KMS ARN, config bucket, ExternalId) as parameters.

## Trust policy mismatch

The management role's trust policy must be the guide's *Trusted entity*
verbatim. IAM stores a one-item `Action` list as a plain string; that is the
same policy. `verify` normalises this before comparing.

## Import fills the form but Confirm stays disabled

The footer counts required fields left. Common misses: Space (the JSON needs a
space **id**), an AZ row with no subnet, a VPC ID that does not start with `vpc-`.

## Typing into the form via browser automation

The VPC ID box pre-renders `vpc-` as placeholder text. Select-all keyboard
shortcuts can be typed as literal characters; triple-click then Delete clears
it reliably. The Availability Zone options carry no accessible text (they are
`a`–`f` in order) and stale option refs from an earlier dropdown can linger —
click by position after a screenshot.

## AWS MCP connector sandbox quirks (aws___run_script)

- The code is validated statically before it runs. Rejected anywhere in the
  text, even in functions never called: `@property`, `getattr()`, `globals()`,
  and imports of `boto3`, `botocore`, `argparse`, `urllib`. `ClientError` is not
  defined despite the tool docs. That is why `olh_core.py` (sandbox-safe, pasted
  into `run_script`) is separate from `olh_build.py` (local boto3 CLI).
- The connector can show *connected* in Settings yet refuse `run_script` with
  "This connector requires authentication" until its AWS sign-in completes.
- Claude Code's auto-mode classifier may block resource creation through the
  connector as an infrastructure apply. The user unblocks it by allowing the
  `…__aws___run_script` tool in project settings.

## Teardown

Delete the integration in Qlik first (Lakehouse clusters tab: delete the cluster;
then the integration). Deleting the integration removes only Qlik's gateway — the
roles, buckets, KMS key and network built by this skill stay and are yours to
remove. KMS keys can only be scheduled for deletion (7–30 days).
