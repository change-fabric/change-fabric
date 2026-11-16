# change-fabric account infrastructure

The Terraform root that owns no workload. It watches the others: the
`cf-alerts` SNS topic (`alerts.tf`), CloudWatch alarms (`alarms.tf`), a
management-events CloudTrail (`cloudtrail.tf`), budgets and cost anomaly
detection (`cost.tf`), and IAM Access Analyzer plus a password policy
(`security.tf`).

It has its own state and references every other root by literal identifier in
`variables.tf`, never by `terraform_remote_state`, so it applies cleanly
whatever is in flight elsewhere. A stale identifier shows up as an alarm stuck
in `INSUFFICIENT_DATA`; update the map in the same change that replaces a
distribution, API, or function.

## Apply

```
cd account/infra
export AWS_PROFILE=personal
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Nothing here is referenced by another root; a destroy removes monitoring only.

## Manual step

The SNS email subscription stays `PendingConfirmation` until its link is
clicked, so a green apply does not prove an alert can be delivered. Check with
`aws sns list-subscriptions-by-topic` against the `cf-alerts` topic.

## Notes

Alarms whose targets were torn down are guarded with `count = 0` and come back
with the redeploy. `backup/route53-*.json` holds exported records of deleted
zones; they are the undo. Per-account budgets filter on `LinkedAccount` at run
rate plus about 20 percent. The history behind these choices is in git.
