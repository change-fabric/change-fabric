---
change_config:
  project: example
  default_profile: staging
  boot:
    target_url: http://app:3000
    health:
      url: http://localhost:3000/up
  lanes:
    zap:
      targets: ["/", "/admin"]
    a11y:
      routes: ["/"]
  profiles:
    staging:
      boot:
        target_url: https://staging.example.test
change_policy:
  protected_branches: [main]
  promotion:
    "tag:v*":
      require_change_pass: true
---

Synthetic fixture for the doctor golden test: no schedules block.
