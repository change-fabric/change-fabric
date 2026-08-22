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
  def suite_yaml(steps:, suite:, id:, acceptance:, tags: [], retries: nil)
    document = suite_document(steps: steps, suite: suite, id: id, acceptance: acceptance,
                              tags: tags, retries: retries)
    verify(document)
    YAML.dump(document)
  end

  def suite_document(steps:, suite:, id:, acceptance:, tags: [], retries: nil)
    raise Error, 'a promoted case needs a suite id' if suite.to_s.strip.empty?
    raise Error, 'a promoted case needs a case id' if id.to_s.strip.empty?
    raise Error, 'a promoted case needs an acceptance criterion' if acceptance.to_s.strip.empty?
    raise Error, 'a promoted case needs at least one step' unless steps.is_a?(Array) && !steps.empty?

    { 'suite' => suite.to_s.strip, 'cases' => [ case_document(steps, id, acceptance, tags, retries) ] }
  end

  def case_document(steps, id, acceptance, tags, retries)
    entry = { 'id' => id.to_s.strip }
    list = Array(tags).map(&:to_s).map(&:strip).reject(&:empty?)
    entry['tags'] = list unless list.empty?
    entry['acceptance'] = acceptance.to_s.strip
    entry['retries'] = retries.to_i if retries.to_i.positive?
    entry['steps'] = steps
    entry
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
