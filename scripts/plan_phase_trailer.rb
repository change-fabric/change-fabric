# frozen_string_literal: true

# The link from a PR to the plan phase it lands, for PRs opened outside
# cf:sweep stack mode (which records the same ref as stack_store's `phase`
# field). A ref reads `<area>/<slug>#Phase <N>`; the trailer is one line in the
# PR body, `Plan-Phase: <ref>`. Pure functions, no IO.
module PlanPhaseTrailer
  KEY = 'Plan-Phase'
  REF = %r{[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#Phase [1-9][0-9]*}
  REF_ONLY = /\A#{REF}\z/
  LINE = /^[ \t]*#{KEY}:[ \t]*(#{REF})[ \t]*\r?$/

  module_function

  def valid?(ref) = ref.is_a?(String) && REF_ONLY.match?(ref)

  # The first trailer's ref in `body`, or nil when none is well formed.
  def parse(body)
    body.to_s[LINE, 1]
  end

  def line(ref)
    raise ArgumentError, "not a plan phase ref: #{ref.inspect}" unless valid?(ref)

    "#{KEY}: #{ref}"
  end
end
