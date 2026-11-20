#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'tempfile'
require_relative 'change_suite'

# Renders a flow that was just explored as a committed test-case suite file.
#
# This is the ending `cf:qa` gained: exploratory QA used to finish as a
# transcript, so the flow a person worked out by hand evaporated with the
# session and the next regression in it went uncaught. Rendering the same steps
# as a suite file makes the exploration an artifact, reviewed like code and
# replayed by the testcases lane forever after.
#
# It renders, it never commits and never writes on its own. The caller offers
# the rendered YAML as a diff and writes it only on an explicit answer: a test
# case that appeared in a repo without anybody choosing it is a check nobody
# owns.
#
# Every render is verified by parsing it back through ChangeSuite, the same
# parser the lane uses, before it is returned. A "suite file" that the lane
# would refuse is worse than no output, because it is discovered at gate time
# rather than here.
module ChangeSuiteRender
  Error = Class.new(StandardError)

  module_function

  # `steps` is the flow's raw declarative step list, exactly as it was run: the
  # suite file's step vocabulary IS the flow file's, so promotion is a re-frame
  # rather than a translation, and nothing can be lost in it.
  #
  # `base_url` is deliberately dropped. A flow file names the host it explored;
  # a suite file must not, because the lane supplies the base url per profile
  # and a case pinned to one developer's localhost is a case that only ever runs
  # for that developer.
  #
  # A retry budget is carried only beside `safe_rerun: true`: a rerun replays
  # every action of the failed attempt, and promotion cannot decide for the
  # author that doing so is safe. Without it the budget is dropped
  # (#dropped_retries? says so) rather than rendered into a file the lane
  # would refuse.
  #
  # `persona` names the login the case runs as (suite_version 3), in place of
  # login steps the flow walked through by hand.
  def suite_yaml(steps:, suite:, id:, acceptance:, tags: [], retries: nil, safe_rerun: false, persona: nil)
    document = suite_document(steps: steps, suite: suite, id: id, acceptance: acceptance,
                              tags: tags, retries: retries, safe_rerun: safe_rerun, persona: persona)
    verify(document)
    YAML.dump(document)
  end

  def dropped_retries?(retries, safe_rerun) = retries.to_i.positive? && safe_rerun != true

  def suite_document(steps:, suite:, id:, acceptance:, tags: [], retries: nil, safe_rerun: false, persona: nil)
    raise Error, 'a promoted case needs a suite id' if suite.to_s.strip.empty?
    raise Error, 'a promoted case needs a case id' if id.to_s.strip.empty?
    raise Error, 'a promoted case needs an acceptance criterion' if acceptance.to_s.strip.empty?
    raise Error, 'a promoted case needs at least one step' unless steps.is_a?(Array) && !steps.empty?

    rerun = retries.to_i.positive? && safe_rerun == true
    persona = persona.to_s.strip
    persona = nil if persona.empty? || persona == 'default'
    document = { 'suite' => suite.to_s.strip }
    version = needed_version(rerun, persona, steps)
    document['suite_version'] = version if version > ChangeSuiteSchema::DEFAULT_SUITE_VERSION
    document.merge('cases' => [ case_document(steps, id, acceptance, tags, rerun ? retries : nil, persona) ])
  end

  # The lowest suite_version that carries every field the case uses.
  def needed_version(rerun, persona, steps = [])
    verbs = Array(steps).flat_map { |step| step.is_a?(Hash) ? step.keys.map(&:to_s) : [] }
    verb_versions = verbs.map { |verb| ChangeSuiteSchema.verb_version(verb) }
    fields = []
    fields << 'cases[].safe_rerun' if rerun
    fields << 'cases[].persona' if persona
    ([ ChangeSuiteSchema::DEFAULT_SUITE_VERSION ] + verb_versions +
      fields.map { |field| ChangeSuiteSchema.field_version(field) }).max
  end

  def case_document(steps, id, acceptance, tags, retries, persona = nil)
    entry = { 'id' => id.to_s.strip }
    entry['persona'] = persona if persona
    list = Array(tags).map(&:to_s).map(&:strip).reject(&:empty?)
    entry['tags'] = list unless list.empty?
    entry['acceptance'] = acceptance.to_s.strip
    if retries.to_i.positive?
      entry['retries'] = retries.to_i
      entry['safe_rerun'] = true
    end
    entry['steps'] = steps
    entry
  end

  # A QA handoff comment template for a whole suite, as Markdown a person
  # pastes into a ticket or PR: per case, what it measures, the figures it
  # captures, the verdict buckets, and blanks for the tester. Generated from the
  # suite so the template can never describe a case the suite does not have.
  def handoff(suite)
    lines = [ "## QA handoff: #{suite.name}", '', 'Tester: ____  Build: ____  Date: ____', '' ]
    suite.cases.each { |item| lines.concat(handoff_case(item)) }
    lines << 'Overall: ____'
    "#{lines.join("\n")}\n"
  end

  HANDOFF_BUCKETS = 'pass / fail / drift / blocked (not verified)'

  def handoff_case(item)
    steps = ChangeFlowCompiler.new(item.steps, base_url: 'http://handoff.invalid', env: {}).compile
    figures = steps.filter_map { |step| step[:as] || step[:var] if %w[capture expectStable].include?(step[:verb]) }.uniq
    [ "### #{item.qualified_id}", '',
      "- Measures: #{item.acceptance.to_s.strip.gsub(/\s+/, ' ')}",
      "- Figures: #{figures.empty? ? 'none captured' : figures.join(', ')}",
      "- Verdict (#{HANDOFF_BUCKETS}): ____",
      '- Observed values and as-of time: ____',
      '- Notes: ____', '' ]
  rescue ChangeFlowCompiler::Error => e
    [ "### #{item.qualified_id}", '', "- Steps could not be compiled: #{e.message}", '' ]
  end

  # The round-trip check: dump, parse with the lane's own parser, and confirm
  # the case survived with its steps intact. Done through a real temp file
  # because ChangeSuite.load_file is the entry point the lane uses, and a check
  # that exercised some other path would be checking something else.
  def verify(document)
    Tempfile.create([ 'cf-promoted', '.cf-testcases.yml' ]) do |file|
      file.write(YAML.dump(document))
      file.flush
      parsed = ChangeSuite.load_file(file.path)
      expected = document.fetch('cases').first
      actual = parsed.cases.first
      raise Error, 'rendered suite did not round-trip: the case id changed' unless actual.id == expected['id']
      raise Error, 'rendered suite did not round-trip: the steps changed' unless actual.steps == expected['steps']
    end
  rescue ChangeSuite::Error => e
    raise Error, "rendered suite is not a valid suite file: #{e.message}"
  end
end

if $PROGRAM_NAME == __FILE__
  args = ARGV.dup
  if args.delete('--handoff') && args.size == 1
    print ChangeSuiteRender.handoff(ChangeSuite.load_file(args.first))
  else
    warn 'usage: change_suite_render.rb --handoff <suite.cf-testcases.yml>'
    exit 2
  end
end
