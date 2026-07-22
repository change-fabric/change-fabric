---
name: cf:terraform
description: Terraform safe-change rubric. Auto-applied by the cf shim on every Terraform change; also invocable directly.
auto:
  extensions: [tf, tfvars]
  detect: ["*.tf", .terraform.lock.hcl]
---

# Terraform Cheat Sheet

Source: HashiCorp Terraform Docs, Style Guide, Standard Module Structure
Secondary lens: Mitchell Hashimoto / Terraform IaC philosophy

Question: Can infrastructure changes be reviewed, planned, and applied safely?

Favor:
- declarative resources
- `terraform fmt`
- `terraform validate`
- remote/shared state
- pinned providers and modules
- small root modules
- standard module structure
- explicit variable types and descriptions
- explicit output descriptions
- least-privilege IAM
- secrets marked sensitive
- modules only when reuse justifies them
- clear ownership boundaries

Avoid:
- hardcoded secrets
- manual console dependencies
- giant root modules
- copy/paste infrastructure
- unpinned providers and modules
- provisioners unless last resort
- clever locals and expressions
- hidden dependencies
- module abstraction too early

Red flags:
- large or surprising plans
- state drift
- broad IAM policies
- resources renamed without moved blocks
- data sources masking unmanaged infra
- module inputs mirroring every resource argument

CI:
- `terraform fmt -check`
- `terraform validate`
- `terraform plan`
- policy/security scan when available

Agent protocol:
1. Preserve existing resources and state.
2. Minimize the plan diff.
3. Prefer declarative config.
4. Keep modules boring.
5. Expose only useful inputs and outputs.
6. Do not change infra behavior accidentally.
