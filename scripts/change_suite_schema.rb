#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_flow_compiler'

# The canonical registry of the test-case suite-file schema: every field a
# suite file may carry, as a dotted path.
#
# Deliberately NOT part of ChangeSchema::FIELDS. A suite file is a different
# document from CHANGE.md: it lives beside the code it tests (a sidecar such as
# `qa/checkout.cf-testcases.yml`, referenced from CHANGE.md by glob under
# `change_config.lanes.testcases.suites`), it is authored by whoever owns that
# flow rather than by whoever owns the repo's governance, and it changes on that
# flow's own schedule. Folding it into the CHANGE.md registry would tie a new
# step verb to a CHANGE.md spec version bump and would tell a reader of the
# frontmatter spec that these keys belong in their frontmatter, which they never
# do.
#
# It gets its own drift test (test/change_suite_schema_spec_test.rb) against its
# own human-facing doc, exactly as ChangeSchema does, so the two documents stay
# honest independently.
module ChangeSuiteSchema
  # The human-facing authority the drift test checks this registry against.
  SPEC_DOC = 'skills/testcases/reference/suite-file-spec.md'

  # `[]` marks a field on each item of a list, the same convention
  # ChangeSchema::FIELDS uses.
  FIELDS = [
    # The suite's own id. Names the suite in a report and in a `--suite`
    # selection; it is not derived from the filename, so moving the file never
    # silently renames the suite.
    'suite',
    'cases[].id',
    'cases[].tags',
    # The human-prose criterion: what a person means by "working" for this
    # case. Required. Graded against what the run observed
    # (ChangeAcceptanceGrader) and rendered beside that verdict in the report;
    # the verdict can fail the gate.
    'cases[].acceptance',
    'cases[].retries',
    # The declarative step list, compiled by ChangeFlowCompiler. Each entry is
    # a mapping naming exactly one verb from STEP_VERBS.
    'cases[].steps'
  ].freeze

  # The step vocabulary is the compiler's, not a second copy of it: a verb the
  # compiler grows is a verb a suite file may use the same day, and a suite
  # validator that kept its own list would reject valid steps or accept steps
  # nothing can compile.
  STEP_VERBS = ChangeFlowCompiler::VERBS
end
