---
goal: Users can sign in once and reach every app in the suite.
epic_rev: 1
repos: [sample-org/api, sample-org/web, other-org/shared-lib]
constraints:
  - No breaking API change without a version bump.
criteria:
  - {id: SC1, text: Token issued by api is accepted by web, owner: demo/web-sso}
  - {id: SC2, text: Shared client validates tokens, owner: demo/shared-token-client}
  - {id: SC3, text: Every sign in is audited, owner: demo/nowhere}
plans:
  - {id: P1, repo: other-org/shared-lib, dir: demo/shared-token-client}
  - {id: P2, repo: sample-org/api, dir: demo/api-token-issue, paths: ["app/auth/**"]}
  - {id: P3, repo: sample-org/web, dir: demo/web-sso}
  - {id: P4, repo: sample-org/api, dir: demo/api-audit-log, paths: ["app/audit/**"]}
edges:
  - {from: "P1#Phase 1", to: "P2#Phase 1"}
  - {from: "P2#Phase 2", to: "P3#Phase 1"}
  - {from: "P1#Phase 2", to: "P3#Phase 2"}
---
Synthetic defect fixture: orphan criterion.
