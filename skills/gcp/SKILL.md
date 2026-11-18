---
name: cf:gcp
group: rubrics
description: Google Cloud Well-Architected Framework rubric. Auto-applied by the cf shim in Google Cloud projects (App Engine, Cloud Build); also invocable directly.
auto:
  basenames: [app.yaml, cloudbuild.yaml, cloudbuild.yml, .gcloudignore]
  detect: [cloudbuild.yaml, cloudbuild.yml, .gcloudignore, app.yaml]
lens:
  keywords: [Cloud Run, GKE, Google Kubernetes Engine, BigQuery, Cloud Storage, Pub/Sub, Cloud SQL, Firestore, Cloud Functions, Spanner, Compute Engine, App Engine, Cloud Build]
---

# Google Cloud Well-Architected

Source: Google Cloud Well-Architected Framework (formerly the Google Cloud Architecture Framework), https://cloud.google.com/architecture/framework. Sections follow Google's own pillars as listed in its table of contents. Summarized in our own words; read the framework for the authoritative text.

Use this rubric on Google Cloud code, infrastructure, or a plan that puts a workload on Google Cloud. Each pillar gives the question to ask, what to favor, the smells that mean the answer is no, and the first fix. Judge the change in front of you; a one-file edit does not owe a pillar's whole program.

## Operational excellence

Question: Can the team deploy, observe, and change this workload safely and repeatedly?

Favor:
- projects, IAM, and services declared in code (Terraform, Config Connector, or Deployment Manager successors) and deployed by Cloud Build or another pipeline
- gradual rollouts: Cloud Run revisions with traffic splitting, GKE progressive delivery
- Cloud Logging and Cloud Monitoring with SLOs on what users feel, and alerting policies with an owner
- a runbook per alert, and post-incident reviews that change something

Smells:
- resources clicked together in the console with no code behind them
- deploys that replace the running version all at once with no traffic split
- dashboards nobody watches and no SLO behind any alert
- one project holding every environment

Default fix: put the drift in code, define one SLO with a burn-rate alert, and split traffic on the next deploy.

## Security, privacy, and compliance

Question: Is access limited to what each identity needs, is data protected, and can the team show it meets its obligations?

Favor:
- a resource hierarchy (organization, folders, projects) that separates environments and teams
- a dedicated service account per workload with narrow predefined or custom roles
- Workload Identity (GKE) and Workload Identity Federation (CI) instead of exported keys
- Secret Manager for secrets; Cloud KMS or CMEK where policy requires customer keys
- VPC Service Controls and private access for sensitive data services
- organization policies that block public buckets and external IPs by default
- audit logs kept and reviewed; data residency stated where it matters

Smells:
- the default compute service account with Editor on the project
- downloaded service account key files in repos or CI variables
- `allUsers` on a bucket or a Cloud Run service that should be private
- primitive roles (Owner, Editor) granted to people or workloads

Default fix: give the workload its own service account with the narrowest role, replace the key with federation, and remove public bindings.

## Reliability

Question: When a zone, region, or dependency fails, does the workload keep serving within its targets and recover its data?

Favor:
- regional services (regional Cloud Run, regional GKE, Cloud SQL high availability) for anything that must stay up
- Spanner or multi-region storage only when the recovery target needs it
- retries with backoff, idempotent handlers, and Pub/Sub with dead-letter topics between services
- health checks that test real readiness, and quotas checked ahead of launches
- backups with restores that have been exercised, and stated RTO and RPO

Smells:
- a single zonal VM or zonal cluster holding state
- synchronous chains of services where one slow call stalls the rest
- Pub/Sub subscribers that are not idempotent under redelivery
- backups that have never been restored

Default fix: make handlers idempotent, decouple the slow dependency with Pub/Sub and a dead-letter topic, and run one restore drill.

## Cost optimization

Question: Is spend visible, attributed, and tied to the value the workload produces?

Favor:
- labels on every resource and billing export to BigQuery for analysis
- budgets with alerts per project or team
- scale to zero (Cloud Run, Cloud Functions) for spiky or idle services
- committed use discounts for steady load, Spot VMs for interruptible batch
- storage classes and lifecycle rules set when a bucket is created
- BigQuery queries that read only the partitions and columns they need

Smells:
- no labels and no budget alerts
- always-on VMs or minimum instances for traffic that is mostly idle
- BigQuery `SELECT *` over unpartitioned tables on a schedule
- cross-region egress nobody priced

Default fix: label it, set a budget alert, partition and cluster the hot tables, and let idle services scale to zero.

## Performance optimization

Question: Does each component get the resources its load needs, measured rather than guessed?

Favor:
- load tests and profiling (Cloud Profiler, Cloud Trace) before sizing decisions
- autoscaling on a signal that tracks demand (requests, queue depth, CPU where it fits)
- Cloud CDN and Memorystore in front of repeated reads
- data stores chosen from the access pattern (Firestore, Bigtable, Spanner, Cloud SQL)
- services placed close to their users and their data

Smells:
- machine types chosen once and never revisited
- a hot Cloud SQL instance doing work a cache or a read replica should do
- chatty calls across regions on the request path
- performance claims with no trace or benchmark behind them

Default fix: trace the hot path, fix the slowest call, and add a cache only where the trace shows repeated reads.

## Sustainability

Question: Does the workload use no more compute, storage, and transfer than its outcome needs, in places with lower carbon impact where latency allows?

Favor:
- regions with lower grid carbon intensity when the workload can choose (Google publishes region carbon data)
- serverless and autoscaled services that release idle capacity
- batch work scheduled into flexible windows
- data retention and storage classes matched to how often data is read
- the Carbon Footprint report watched alongside cost

Smells:
- capacity sized for a rare peak and left on all month
- duplicate datasets kept in several places
- polling loops where Pub/Sub or Eventarc would do

Default fix: replace polling with events, trim retention, and pick the lower-carbon region when nothing else constrains the choice.

## Planning checks

Apply these to a plan or design doc before code exists:

1. Every new project, service, and binding is named with the tool that will define it in code.
2. Each workload has its own service account and a listed set of roles.
3. No step relies on downloaded service account keys.
4. Each data store states its access pattern, location, backup, and restore test.
5. The plan states which pieces are zonal, regional, or multi-region and why.
6. Calls between services are justified as synchronous, or go through Pub/Sub.
7. The SLOs and alerts users would feel first are named, with an owner.
8. The expected cost driver is named, with the labels and budget that track it.
9. Public exposure (Cloud Run ingress, buckets, load balancers) is listed and justified.
10. The rollback for the first deploy is written down.

## Agent protocol

1. Read the change through all six pillars, then report only the findings that matter for this change.
2. Prefer managed and serverless primitives over self-run ones.
3. Narrow identity and network exposure before adding features.
4. Make failure observable and recoverable.
5. Do not add complexity without a clear operational payoff.
