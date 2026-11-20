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

  # The suite-file format's own version, an integer independent of
  # ChangeSchema::VERSION. A file declares the version it was written against in
  # its top-level `suite_version`; a file with none is version 1, exactly the
  # field set before the key existed. Every PR that adds a suite field raises
  # this by one and records the field in FIELD_VERSIONS, so an install can tell
  # a file written for a newer toolkit from a file with a typo.
  SUITE_VERSION = 5

  # The version a file declares when it says nothing.
  DEFAULT_SUITE_VERSION = 1

  # What an install says to a file newer than itself. One string, used by the
  # loader, the lane and doctor alike.
  def self.too_new_message(declared)
    "suite_version #{declared} needs a newer cf toolkit; pull and run ruby install.rb " \
      "(this install reads suite_version up to #{SUITE_VERSION})"
  end

  # `[]` marks a field on each item of a list, the same convention
  # ChangeSchema::FIELDS uses.
  FIELDS = [
    # The suite's own id. Names the suite in a report and in a `--suite`
    # selection; it is not derived from the filename, so moving the file never
    # silently renames the suite.
    'suite',
    # The suite-file version this file was written against (integer, default
    # 1). Checked before anything else, so a newer file fails with an update
    # message instead of an unknown-key error on its first new field.
    'suite_version',
    'cases[].id',
    'cases[].tags',
    # The human-prose criterion: what a person means by "working" for this
    # case. Required. Graded against what the run observed
    # (ChangeAcceptanceGrader) and rendered beside that verdict in the report;
    # the verdict can fail the gate.
    'cases[].acceptance',
    'cases[].retries',
    # (v2) A whole-case rerun replays every mutation the failed attempt already
    # made, so `retries` is refused unless the author says it is safe.
    'cases[].safe_rerun',
    # (v2) This case's browserless call budget in ms (1000..600000). Without
    # it the lane derives one from the steps' timeouts.
    'cases[].timeout_ms',
    # (v3) The persona this case runs as: a name under
    # lanes.testcases.personas, `default` (the lane's `auth:`), or `anonymous`
    # (no login). Unset means `default`.
    'cases[].persona',
    # (v3) Whether a mutating step interrupted by an expired session may be
    # replayed after the re-login. Off by default, because the action may
    # already have taken effect server side.
    'cases[].safe_retry',
    # (v3) The case ends its own session on purpose (a logout test), so
    # session-end detection and its re-login are off for it.
    'cases[].expects_logout',
    # The time-boxed flake quarantine. All three keys or none: a quarantine
    # without a reason cannot be told from a defect somebody muted, and one
    # without an expiry is permanent, which is the state this feature exists to
    # make unreachable. A quarantined case still runs and still reports; only
    # its power to fail the gate is suspended, and only until the date.
    'cases[].quarantined',
    'cases[].quarantine_reason',
    'cases[].quarantine_until',
    # The declarative step list, compiled by ChangeFlowCompiler. Each entry is
    # a mapping naming exactly one verb from STEP_VERBS.
    'cases[].steps'
  ].freeze

  # The suite_version that introduced each field. A field absent here is a
  # version 1 field. A file that uses a field newer than the version it
  # declares is refused with the version that adds it named.
  FIELD_VERSIONS = {
    'suite_version' => 2,
    'cases[].safe_rerun' => 2,
    'cases[].timeout_ms' => 2,
    'cases[].persona' => 3,
    'cases[].safe_retry' => 3,
    'cases[].expects_logout' => 3
  }.freeze

  def self.field_version(field) = FIELD_VERSIONS.fetch(field, DEFAULT_SUITE_VERSION)

  # The suite_version that introduced each step verb; a verb absent here is a
  # version 1 verb. Same rule as FIELD_VERSIONS: a file using a verb newer than
  # it declares is refused with the version that adds it.
  VERB_VERSIONS = (ChangeFlowCompiler::STATE_WAITS + ChangeFlowCompiler::EVENT_WAITS).to_h { |verb| [ verb, 4 ] }
                                                                                    .merge('expect_stable' => 5).freeze

  def self.verb_version(verb) = VERB_VERSIONS.fetch(verb, DEFAULT_SUITE_VERSION)

  # (v5) The step option and the read kinds newer than version 1, gated the
  # same way: a v4 file using them is refused naming the version that adds them.
  OPTION_VERSIONS = { 'budget_ms' => 5, 'budget_from' => 5, 'label' => 5, 'tolerance' => 5, 'tolerance_px' => 5, 'wait' => 5, 'max_cls' => 5 }.freeze
  KIND_VERSIONS = ChangeFlowCompiler::MEASURED_KINDS.to_h { |kind| [ kind, 5 ] }.freeze

  def self.option_version(option) = OPTION_VERSIONS.fetch(option, DEFAULT_SUITE_VERSION)

  def self.kind_version(kind) = KIND_VERSIONS.fetch(kind, DEFAULT_SUITE_VERSION)

  # The keys a suite file may carry at the top level and on each case, derived
  # from FIELDS so the strict loader and the drift test read one list.
  TOP_KEYS = (FIELDS.reject { |field| field.include?('.') } + [ 'cases' ]).freeze
  CASE_KEYS = FIELDS.filter_map { |field| field.delete_prefix('cases[].') if field.start_with?('cases[].') }.freeze

  # The step vocabulary is the compiler's, not a second copy of it: a verb the
  # compiler grows is a verb a suite file may use the same day, and a suite
  # validator that kept its own list would reject valid steps or accept steps
  # nothing can compile.
  STEP_VERBS = ChangeFlowCompiler::VERBS
end
