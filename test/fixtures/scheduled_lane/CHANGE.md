---
scheduled_lanes:
  - id: example
    run: sh test/fixtures/scheduled_lane/example_lane.sh
    result_file: tmp/example-result.json
    deployed_sha_cmd: echo 0123456789abcdef0123456789abcdef01234567
    cadence: nightly
    timeout_minutes: 5
    dispatch_inputs: [ref, lanes, matrix, release_tag, approved_keys]
    matrix:
      mode: touched-one-at-a-time
      touched_cmd: printf 'example_flag\n'
      flip_cmd: echo flip {flag} in {env}
      revert_cmd: echo revert {flag} in {env}
      read_cmd: echo off
      list_on_cmd: "true"
      ledger_cmd: "true"
      lock_group: example-env-flags
      max_flags: 3
      settle_seconds: 0
      revert_headroom_seconds: 60
      forbid_envs: [production]
    sinks:
      - type: github_issue
        labels: [scheduled-lane]
        assignee_on_app_failure: example-qa
        assignee_on_infra_failure: example-lead
      - type: release_comment
      - type: chat_dm
        cmd: cat
---

# Fixture

A generic scheduled-lane declaration used by the tests.
