---
name: pst:aws
description: AWS Well-Architected rubric. Auto-applied by the pst shim in AWS infrastructure projects; also invocable directly.
auto:
  basenames: [cdk.json, serverless.yml, serverless.yaml, samconfig.toml, template.yaml, template.yml, aws-exports.js]
  detect: [cdk.json, serverless.yml, serverless.yaml, samconfig.toml, template.yaml, template.yml, aws-exports.js, .aws]
---

# AWS Cheat Sheet

Source: AWS Well-Architected Framework, AWS Builders' Library
Secondary lens: Werner Vogels / distributed systems resilience

Question: Is this workload secure, reliable, operable, efficient, cost-aware, and sustainable?

Favor:
- least-privilege IAM
- managed services
- encryption by default
- no long-lived credentials
- secrets in managed secret stores
- infrastructure as code
- observable workloads
- alarms on user-impacting symptoms
- backups with tested restores
- multi-AZ where availability matters
- autoscaling and right-sizing
- loose coupling
- graceful failure handling
- cost visibility
- sustainability-aware resource choices

Avoid:
- public access by default
- wildcard IAM
- public databases
- unmanaged secrets
- manual deployments
- single points of failure
- missing alarms
- missing recovery plan
- overprovisioned idle resources
- service sprawl without ownership

Review lenses:
- Operational Excellence
- Security
- Reliability
- Performance Efficiency
- Cost Optimization
- Sustainability

Red flags:
- no runbook
- no owner
- no backup/restore proof
- no threat model
- no cost tags or budgets
- synchronous chains where async would reduce blast radius

Agent protocol:
1. Start with the Well-Architected pillars.
2. Reduce blast radius.
3. Prefer managed primitives.
4. Make failure observable and recoverable.
5. Preserve business requirements.
6. Do not add complexity without a clear operational payoff.
