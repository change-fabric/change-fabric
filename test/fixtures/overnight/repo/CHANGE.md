---
change_config:
  project: overnight-fixture
  lanes:
    browserless: {}
    a11y: {}
  profiles:
    prod:
      lanes:
        browserless: {}
        testcases: {}
        k6: { enabled: false }
change_policy:
  gate:
    trunk: main
  promotion:
    "tag:v*":
      environment: production
      profile: prod
---

# Fixture governance

Production ships on a `v*` tag.
