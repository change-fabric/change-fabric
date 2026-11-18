---
name: cf:aws
group: rubrics
description: AWS Well-Architected rubric. Auto-applied by the cf shim in AWS infrastructure projects; also invocable directly.
auto:
  basenames: [cdk.json, serverless.yml, serverless.yaml, samconfig.toml, template.yaml, template.yml, aws-exports.js]
  detect: [cdk.json, serverless.yml, serverless.yaml, samconfig.toml, template.yaml, template.yml, aws-exports.js, .aws]
lens:
  keywords: [Lambda, DynamoDB, S3, CloudFront, ECS, Fargate, EKS, RDS, Aurora, SQS, SNS, EventBridge, CloudFormation, CDK]
---

# AWS Well-Architected

Source: AWS Well-Architected Framework, https://aws.amazon.com/architecture/well-architected/ (six pillars). Summarized in our own words; read the framework for the authoritative text.

Use this rubric on AWS code, infrastructure, or a plan that puts a workload on AWS. Each pillar below gives the question to ask, what to favor, the smells that mean the answer is no, and the fix to reach for first. Judge the change in front of you; do not demand a pillar's full program from a one-file edit.

## Operational excellence

Question: Can the team run, change, and learn from this workload without heroics?

Favor:
- every resource defined in code (CDK, CloudFormation, SAM, or Terraform) and deployed by a pipeline
- small, frequent, reversible deploys with an automatic rollback signal
- structured logs, metrics, and traces that name the request, not just the host
- alarms on what users feel (error rate, latency, queue age), routed to an owner
- a runbook per alarm and a named owner per service

Smells:
- console changes that the code does not know about
- a deploy that cannot be rolled back, or that needs a manual step
- alarms on CPU alone, or alarms nobody receives
- no record of what changed when an incident starts

Default fix: move the drift into code, add one user-facing alarm with an owner and a runbook link, and make the deploy reversible before adding anything else.

## Security

Question: Is every identity, network path, and piece of data limited to what the workload needs?

Favor:
- IAM roles with least privilege, scoped to named resources and actions
- short-lived credentials from roles or identity federation, never access keys in code
- secrets in Secrets Manager or Parameter Store, rotated
- encryption at rest with KMS and in transit with TLS everywhere
- private subnets and VPC endpoints for data stores; nothing public by default
- CloudTrail, GuardDuty, and config rules on, with findings that reach a person

Smells:
- `*` in an IAM action or resource without a written reason
- a public S3 bucket, security group open to 0.0.0.0/0 on a data port, or a public database
- long-lived keys in environment variables, repos, or CI settings
- one account for every environment

Default fix: narrow the policy to the resources the code touches, swap the key for a role, and put the data store behind the VPC.

## Reliability

Question: When a component, zone, or dependency fails, does the workload recover on its own and lose nothing important?

Favor:
- multi-AZ for anything stateful that the business needs to stay up
- timeouts, retries with backoff and jitter, and idempotent handlers
- queues (SQS, EventBridge) between services instead of synchronous chains
- service quotas known and alarmed before they bite
- backups with a restore that has actually been tested, and stated RTO and RPO

Smells:
- a single instance or single AZ holding state
- retries without backoff, or retries on a non-idempotent write
- a Lambda that waits synchronously on three other services
- a backup plan with no restore drill

Default fix: make the handler idempotent, put a queue with a dead-letter queue in front of the slow dependency, and schedule one restore test.

## Performance efficiency

Question: Does the design use the right resource type and size for the load it actually sees, and can it adapt?

Favor:
- managed and serverless services where the load is spiky or unknown
- autoscaling on a metric that tracks demand
- caching (CloudFront, ElastiCache, DAX) in front of repeated reads
- data stores chosen for the access pattern (DynamoDB keys designed from the queries)
- load tests that reflect real traffic before launch

Smells:
- instance sizes picked once and never revisited
- a relational database used as a queue, or DynamoDB scans on a hot path
- chatty calls across regions
- no measurement behind a performance claim

Default fix: measure the hot path, design the key or index for the query, and add a cache only where the measurement says it pays.

## Cost optimization

Question: Does every dollar spent map to something the business values, and can the team see it?

Favor:
- cost allocation tags and a budget with alerts per team or service
- right-sized resources, Graviton where it fits, Savings Plans for steady load
- storage lifecycle rules (S3 tiers, log retention) set at creation
- scale to zero for idle environments
- a unit cost (per request, per customer) the team watches

Smells:
- untagged resources and no budget alarm
- NAT gateway or cross-AZ data transfer nobody priced
- logs kept forever by default
- dev environments running all night at production size

Default fix: tag it, set a budget alert, add a lifecycle or retention rule, and schedule idle environments down.

## Sustainability

Question: Does the workload use no more compute, storage, and transfer than its outcome needs?

Favor:
- managed and serverless services that share hardware efficiently
- efficient instance families and regions chosen with energy in mind where latency allows
- data kept only as long as it is used, compressed, and in the right tier
- batch work scheduled for flexible windows

Smells:
- always-on capacity sized for a peak that happens once a month
- duplicate copies of the same data in several stores
- polling loops where an event would do

Default fix: replace polling with events, shrink retention, and let idle capacity scale down.

## Planning checks

Apply these to a plan or design doc before code exists:

1. Every new resource is named with the tool that will define it in code.
2. Each data store states its access pattern, backup, and restore test.
3. Each new IAM role lists the actions and resources it needs.
4. Synchronous calls between services are justified, or replaced by a queue or event.
5. The plan names the alarms users would feel first and who receives them.
6. Stateful pieces state their AZ and region posture and the RTO and RPO they meet.
7. The plan names the expected monthly cost driver and the tag or budget that tracks it.
8. Public exposure (endpoints, buckets, ports) is listed and each item is justified.
9. Secrets have a named store and a rotation story.
10. The rollback path for the first deploy is written down.

## Agent protocol

1. Read the change through all six pillars, then report only the findings that matter for this change.
2. Reduce blast radius before adding features.
3. Prefer managed primitives over self-run ones.
4. Make failure observable and recoverable.
5. Preserve business requirements; do not add complexity without a clear operational payoff.
