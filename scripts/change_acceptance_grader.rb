#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'

# Grades a test case's human-prose `acceptance` criterion against what the run
# actually observed, and returns a verdict the lane turns into a Finding.
#
# Why an LLM is in this one place and nowhere else in the lane: a selector
# assertion answers "is the element there", and a page can render every expected
# element and still do the wrong thing. `acceptance` is the sentence a person
# would use to say the flow worked, and checking prose against an observation is
# the one part of this that cannot be compiled. Everything before it stays pure
# Ruby precisely so the part that is not deterministic is small, named, and
# reported separately rather than smeared across the whole verdict.
#
# The grading verdict CAN fail the gate. It is deliberately not capped at warn:
# a criterion nobody's failure can act on is documentation, not a check. The
# escape hatch for a verdict an author believes is wrong is the sha-scoped
# override the repo already has (`change_override.rb`, which
# `change_merge_guard.rb` consults). There is no second override mechanism here,
# and this file records none: it only says which of the two branches applies.
#
# Grading is skipped, loudly, rather than faked when no grader is reachable. A
# missing grader reports as its own `warn` finding naming what did not run; it
# never becomes a silent pass, and it never fails a run that has no LLM
# available at all (a CI box without the CLI installed).
class ChangeAcceptanceGrader
  # The verdict vocabulary. `unclear` is a real answer, not a parse failure: a
  # grader that cannot tell from the observation should say so and get a warn,
  # rather than guessing in either direction.
  VERDICTS = %w[pass fail unclear].freeze

  # The default grader: the Claude Code CLI in one-shot mode, reading the prompt
  # on stdin. Overridden wholesale by CF_ACCEPTANCE_GRADER, which is a command
  # line with the same contract (prompt on stdin, JSON on stdout), so a repo can
  # point grading at whatever it actually has.
  DEFAULT_COMMAND = %w[claude -p].freeze
  SKIP_ENV = 'CF_SKIP_ACCEPTANCE_GRADING'
  COMMAND_ENV = 'CF_ACCEPTANCE_GRADER'

  # How much of the observed page text travels to the grader. Bounded because a
  # criterion is judged from the visible outcome, not from a whole DOM, and an
  # unbounded page would make the prompt (and the cost) a function of whatever
  # the app happens to render.
  TEXT_LIMIT = 4_000

  Verdict = Struct.new(:id, :verdict, :rationale, keyword_init: true) do
    def pass? = verdict == 'pass'
    def fail? = verdict == 'fail'
  end

  # A session an operator is watching can act on a wrong verdict now; CI cannot,
  # by design. `change_override.rb` refuses without a real TTY precisely so an
  # agent cannot record an override on a human's behalf, so the honest CI
  # behavior is to fail closed and name what the human has to go and do.
  def self.interactive?(stdin: $stdin, env: ENV)
    return false unless env['CI'].to_s.empty?

    stdin.respond_to?(:tty?) && stdin.tty?
  end

  # The one sentence a failing acceptance verdict carries about what to do next.
  # Both branches point at the SAME sha-scoped override; only the reachability
  # differs, which is the whole content of the interactive-vs-CI distinction.
  def self.override_guidance(interactive: interactive?)
    common = 'If this verdict is wrong, the escape hatch is the existing sha-scoped override: ' \
             "ruby ~/.claude/cf/bin/change_override.rb <head sha> --reason '<why>' " \
             '(the head sha is in the report Run block).'
    if interactive
      "#{common} This session is interactive, so it can be recorded now, from this terminal, by a human."
    else
      "#{common} This run is non-interactive, so it fails closed: change_override.rb refuses without a real " \
        'terminal, and no agent can record it on a human\'s behalf.'
    end
  end

  # `runner` is the seam the tests drive: anything responding to #call(prompt)
  # and returning the grader's raw stdout. Left nil, it shells out to the
  # resolved command.
  def initialize(env: ENV, runner: nil)
    @env = env
    @runner = runner
  end

  # The skip switch governs the default, real grader only. An explicitly
  # injected runner is somebody stating what the grader is, which is never the
  # thing the switch is there to turn off.
  def skipped? = @runner.nil? && @env[SKIP_ENV].to_s == '1'

  # The grader command, or nil when nothing is reachable. A configured command
  # is trusted as configured; the default is used only when `claude` is actually
  # on PATH, so an absent CLI reads as "no grader" rather than as a crash.
  def command
    configured = @env[COMMAND_ENV].to_s
    return configured.split unless configured.empty?
    return DEFAULT_COMMAND if @runner || executable?(DEFAULT_COMMAND.first)

    nil
  end

  def available? = !skipped? && (!@runner.nil? || !command.nil?)

  # Why grading did not happen, for the finding that says so. nil when it did.
  def unavailable_reason
    return "acceptance grading was skipped: #{SKIP_ENV}=1" if skipped?
    return nil if available?

    "acceptance grading did not run: no grader is reachable (the #{DEFAULT_COMMAND.first} CLI is not on PATH " \
      "and #{COMMAND_ENV} is unset), so every criterion in this run is unjudged prose."
  end

  # Grades every observation in one call and returns one Verdict per input, in
  # input order. A grader that returns nothing usable for a case yields an
  # `unclear` verdict for it rather than dropping the case: a criterion that
  # silently vanished from the report is the failure mode this whole lane
  # exists to avoid.
  def grade(observations)
    return [] if observations.empty?

    parsed = parse(invoke(prompt_for(observations)))
    observations.map { |observation| verdict_for(observation, parsed) }
  rescue StandardError => e
    observations.map do |observation|
      Verdict.new(id: observation[:id], verdict: 'unclear', rationale: "grader error: #{e.message}")
    end
  end

  # The exact text handed to the grader. Public so a reviewer (and a test) can
  # read what the judgment is actually made from, rather than taking on trust
  # that the observation reached it.
  def prompt_for(observations)
    <<~PROMPT
      You are grading browser test cases. For each case you are given a human-written
      acceptance criterion and an observation of what a scripted browser run actually did.

      Decide, for each case, whether the observation satisfies the criterion.

      Answer with JSON only: an array of objects with the keys "id", "verdict", and
      "rationale". "verdict" is one of #{VERDICTS.join(', ')}. Use "unclear" when the
      observation does not contain enough to decide; do not guess. Keep each rationale
      to one sentence. Emit no prose outside the JSON.

      #{JSON.pretty_generate(observations.map { |observation| payload(observation) })}
    PROMPT
  end

  private

  def payload(observation)
    {
      'id' => observation[:id].to_s,
      'acceptance' => observation[:acceptance].to_s,
      'steps_passed' => observation[:ok] == true,
      'steps' => Array(observation[:steps]).map { |step| step_payload(step) },
      'final_url' => observation[:url].to_s,
      'page_title' => observation[:title].to_s,
      'page_text' => observation[:text].to_s[0, TEXT_LIMIT]
    }
  end

  def step_payload(step)
    { 'step' => step['label'].to_s, 'ok' => step['ok'] == true, 'error' => step['error'].to_s }
  end

  def invoke(prompt)
    return @runner.call(prompt) if @runner

    argv = command
    raise 'no acceptance grader is available' unless argv

    out, status = Open3.capture2e(*argv, stdin_data: prompt)
    raise "grader command failed: #{argv.join(' ')} (#{out.to_s.lines.last(3).join.strip})" unless status.success?

    out
  end

  # Grader output is parsed leniently on the outside and strictly on the inside:
  # a model may wrap JSON in a fence or a sentence, which is not worth failing
  # over, but a verdict token outside the vocabulary is, because "probably pass"
  # is exactly the reading that turns a gate into a coin flip.
  def parse(output)
    text = output.to_s
    first = text.index('[')
    last = text.rindex(']')
    raise 'grader returned no JSON array' if first.nil? || last.nil? || last < first

    rows = JSON.parse(text[first..last])
    raise 'grader returned a JSON value that is not an array' unless rows.is_a?(Array)

    rows.select { |row| row.is_a?(Hash) }.to_h { |row| [ row['id'].to_s, row ] }
  end

  def verdict_for(observation, parsed)
    id = observation[:id].to_s
    row = parsed[id]
    return Verdict.new(id: id, verdict: 'unclear', rationale: 'the grader returned no verdict for this case') unless row

    verdict = row['verdict'].to_s.downcase
    verdict = 'unclear' unless VERDICTS.include?(verdict)
    Verdict.new(id: id, verdict: verdict, rationale: row['rationale'].to_s.strip)
  end

  def executable?(name)
    @env['PATH'].to_s.split(File::PATH_SEPARATOR).any? do |dir|
      path = File.join(dir, name)
      File.file?(path) && File.executable?(path)
    end
  end
end
