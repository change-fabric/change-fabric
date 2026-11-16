---
goal: Users can sign in once and reach every app in the suite.
epic_rev: 1
repos: [sample-org/api, sample-org/web, other-org/shared-lib]
constraints:
  - No breaking API change without a version bump.
criteria:
  - {id: SC1, text: Token issued by api is accepted by web, owner: demo/web-sso}
  - {id: SC2, text: Shared client validates tokens, owner: demo/shared-token-client}
  - {id: SC3, text: Every sign in is audited, owner: demo/api-audit-log}
plans:
  - {id: P1, repo: other-org/shared-lib, dir: demo/shared-token-client}
  - {id: P2, repo: sample-org/api, dir: demo/api-token-issue, paths: ["app/auth/**"]}
  - {id: P3, repo: sample-org/web, dir: demo/web-sso}
  - {id: P4, repo: sample-org/api, dir: demo/api-audit-log, paths: ["app/audit/**"]}
edges:
  - {from: "P1#Phase 1", to: "P2#Phase 1"}
  - {from: "P2#Phase 2", to: "P3#Phase 1"}
  - {from: "P1#Phase 2", to: "P3#Phase 2"}
digests:
  P1: 398ed87314239cad48d35d44107f6da8c6154be10a0cd2797ecef1d2bb166f45
  P2: bd81947fca987b816c6a23be719e5540fb42c919450ef1ea87fadb72e2a0d3cd
  P3: b108e0908f5805ff6875c579389db1079ab2464f5266d87c91b6d1e79a3027ee
  P4: 5b4af2623e5049c5009525852736f84a563e9c1528517bcf922e9a601a70293f
---
Synthetic example epic: single sign on across three repos. Every name here is
made up for the tests.
