---
name: cf:azure
group: rubrics
description: Azure Well-Architected Framework rubric. Auto-applied by the cf shim in Azure projects (Bicep, azd, Functions); also invocable directly.
auto:
  extensions: [bicep]
  basenames: [azure.yaml, host.json, azuredeploy.json]
  detect: [azure.yaml, "*.bicep", host.json]
lens:
  keywords: [Azure Functions, AKS, Azure Kubernetes Service, Cosmos DB, App Service, Blob Storage, Service Bus, Entra ID, Key Vault, Azure SQL, Bicep, Container Apps, Event Grid]
---

# Azure Well-Architected

Source: Azure Well-Architected Framework, https://learn.microsoft.com/azure/well-architected/ (five pillars). Sustainability is covered separately as supplemental workload guidance, not a pillar. Summarized in our own words; read the framework for the authoritative text.

Use this rubric on Azure code, infrastructure, or a plan that puts a workload on Azure. Each pillar gives the question to ask, what to favor, the smells that mean the answer is no, and the first fix. Judge the change in front of you; a one-file edit does not owe a pillar's whole program.

## Reliability

Question: Does the workload meet its uptime and recovery targets when a component, zone, or region fails?

Favor:
- availability zones for stateful and user-facing services that must stay up (zone-redundant App Service plans, zone-redundant storage, Azure SQL zone redundancy)
- retries with backoff, idempotent handlers, and Service Bus queues with dead-lettering between services
- health probes that test real readiness
- reliability targets (SLO, RTO, RPO) written down and tied to the design
- backups and geo-replication with a restore or failover that has been tested

Smells:
- a single instance or a locally redundant store holding data the business cannot lose
- Functions that call several services synchronously and fail together
- message handlers that are not idempotent under redelivery
- a failover plan no one has run

Default fix: make the handler idempotent, put a Service Bus queue with a dead-letter queue in front of the slow dependency, and schedule one restore or failover drill.

## Security

Question: Is every identity, network path, and secret limited to what the workload needs, with integrity and confidentiality kept?

Favor:
- Microsoft Entra ID for people and managed identities for workloads; no secrets where an identity will do
- Azure RBAC roles scoped to the resource group or resource, not the subscription
- Key Vault for secrets, keys, and certificates, with rotation
- private endpoints and network isolation for data services; public access off by default
- Microsoft Defender for Cloud recommendations and Azure Policy guardrails acted on
- separate subscriptions or landing zones per environment

Smells:
- connection strings or keys in app settings, repos, or pipelines when a managed identity is available
- Owner or Contributor granted at subscription scope to a workload
- storage accounts or databases reachable from the public internet without a reason
- one subscription for every environment

Default fix: switch the workload to a managed identity, scope its role to the resources it uses, move the remaining secret to Key Vault, and close public access.

## Cost optimization

Question: Does spend stay within budget, and does each cost map to value the team can see?

Favor:
- tags on every resource and Azure Cost Management budgets with alerts
- consumption plans and scale to zero (Functions, Container Apps) for spiky or idle load
- reservations or savings plans for steady load; spot capacity for interruptible work
- storage access tiers and lifecycle rules set at creation; Log Analytics retention chosen deliberately
- right-sizing reviewed on a schedule

Smells:
- untagged resources and no budget alert
- premium tiers chosen by default for development environments
- Log Analytics ingesting everything at full retention
- idle App Service plans or VMs left running

Default fix: tag it, add a budget alert, drop dev environments to a lower tier or schedule them down, and set retention.

## Operational excellence

Question: Can the team deploy, observe, and change the workload safely, with automation instead of manual steps?

Favor:
- every resource in Bicep or Terraform, deployed by a pipeline (Azure DevOps or GitHub Actions), with `azd` where it fits
- deployment slots or revisions for safe rollout and fast rollback
- Azure Monitor and Application Insights with alerts on user-facing symptoms, routed to an owner
- runbooks for each alert and blameless reviews after incidents

Smells:
- portal changes the templates do not know about
- deploys straight to production with no slot swap or revision split
- alerts on infrastructure counters only, or alerts nobody receives

Default fix: capture the drift in Bicep, deploy through a slot or revision, and add one user-facing alert with an owner and a runbook.

## Performance efficiency

Question: Does the workload adjust to demand through scaling, with performance tested before it reaches production?

Favor:
- horizontal scale-out rules on a signal that tracks demand
- Azure Front Door or CDN and Azure Cache for Redis in front of repeated reads
- data stores chosen for the access pattern, with Cosmos DB partition keys designed from the queries
- load tests (Azure Load Testing or similar) before launch and after major changes
- services placed in regions close to users and data

Smells:
- vertical scaling as the only answer to load
- Cosmos DB hot partitions or cross-partition queries on the hot path
- calls across regions on every request
- no measurement behind a performance claim

Default fix: measure the hot path, fix the partition key or index, and add caching only where the measurement says it pays.

## Sustainability (supplemental, Azure sustainability workload guidance, not a pillar)

Question: Does the workload use no more compute, storage, and transfer than its outcome needs?

Favor:
- scale to zero and autoscaling that release idle capacity
- batch work scheduled into flexible windows
- data kept only as long as it is used, in the right tier
- the Emissions Impact Dashboard watched alongside cost where available

Smells:
- capacity sized for a rare peak and left running
- polling loops where Event Grid or Service Bus would do

Default fix: replace polling with events and let idle capacity scale down.

## Planning checks

Apply these to a plan or design doc before code exists:

1. Every new resource is named with the Bicep or Terraform module that defines it.
2. Each workload has a managed identity and a listed role scoped below the subscription.
3. Secrets that cannot be replaced by an identity have a Key Vault and a rotation story.
4. Each data store states its access pattern, redundancy option, backup, and restore test.
5. The plan states zone and region posture with its RTO and RPO.
6. Calls between services are justified as synchronous, or go through Service Bus or Event Grid.
7. The alerts users would feel first are named, with an owner.
8. The expected cost driver is named, with the tags and budget that track it.
9. Public exposure (endpoints, storage, databases) is listed and justified.
10. The rollback for the first deploy is written down.

## Agent protocol

1. Read the change through the five pillars, then sustainability as supplemental guidance; report only the findings that matter.
2. Prefer managed identities and managed services over secrets and self-run ones.
3. Reduce blast radius before adding features.
4. Make failure observable and recoverable.
5. Do not add complexity without a clear operational payoff.
