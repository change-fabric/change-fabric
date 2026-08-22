#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require_relative 'change_suite_schema'
require_relative 'change_flow_compiler'

# One parsed test-case suite file, and the set of suites a `suites:` glob list
# resolves to.
#
# A suite is a sidecar YAML file living beside the code it tests (conventionally
# `<dir>/<name>.cf-testcases.yml`), referenced from CHANGE.md by glob. It is
# never inline in CHANGE.md: a flow's cases belong with that flow, they are
# reviewed by whoever owns it, and a repo with twenty flows would otherwise
# carry twenty flows' assertions in its governance file.
#
# Parsing is strict and fails by name. A suite that cannot be trusted is worse
# than no suite: a typo'd verb that parsed as "no assertion" would turn a
# regression check into a page load, and the lane would report a pass for a case
# that checked nothing.
class ChangeSuite
  Error = Class.new(StandardError)

  # One case: an id, its tags, the human-prose acceptance criterion, its own
  # retry budget, and the declarative steps. `steps` stays raw here; the lane
  # compiles it through ChangeFlowCompiler, which owns the step vocabulary.
  TestCase = Struct.new(:suite, :id, :tags, :acceptance, :retries, :steps, keyword_init: true) do
    # A case's report-facing name, unique across every loaded suite.
    def qualified_id = "#{suite}/#{id}"

    # Whether this case is selected by a `tags:` filter. An empty filter
    # selects everything, so a lane with no filter runs the whole suite.
    def selected?(filter) = filter.empty? || filter.intersect?(tags)

    # Whether an explicit `--suite <suite-or-tag>` selector names this case.
    # One flag covers both because that is how a person asks for a rerun: they
    # say "the checkout ones", and whether checkout is the suite's name or a tag
    # on its cases is an implementation detail of how somebody filed them.
    def named_by?(selectors) = selectors.include?(suite) || selectors.intersect?(tags)

    # Whether a failure of this case may fail the gate. An empty `gate_tags`
    # means every case gates, which is the default and the point: a test case
    # that cannot fail the build is a comment. `gate_tags` is the staged
    # -adoption escape valve, naming the tags that DO gate while a new suite
    # is still being trusted.
    def gates?(gate_tags) = gate_tags.empty? || gate_tags.intersect?(tags)
  end

  attr_reader :name, :path, :cases

  def initialize(name, path, cases)
    @name = name
    @path = path
    @cases = cases
  end

  # Parses one suite file, raising Error with the offending file named. Every
  # rule here is one the doctor reports and the lane refuses to run past.
  def self.load_file(path)
    raw = YAML.safe_load(File.read(path), aliases: true)
    raise Error, "suite file is not a mapping: #{path}" unless raw.is_a?(Hash)

    name = raw['suite'].to_s
    raise Error, "suite file has no `suite:` id: #{path}" if name.empty?

    new(name, path, parse_cases(raw['cases'], name, path))
  rescue Psych::SyntaxError => e
    raise Error, "suite file is not valid YAML: #{path} (#{e.message})"
  rescue SystemCallError => e
    raise Error, "suite file could not be read: #{path} (#{e.message})"
  end

  def self.parse_cases(raw_cases, name, path)
    raise Error, "suite '#{name}' has no cases: #{path}" unless raw_cases.is_a?(Array) && !raw_cases.empty?

    seen = []
    raw_cases.each_with_index.map do |raw_case, index|
      parsed = parse_case(raw_case, name, path, index)
      raise Error, "suite '#{name}' declares case id '#{parsed.id}' more than once: #{path}" if seen.include?(parsed.id)

      seen << parsed.id
      parsed
    end
  end

  def self.parse_case(raw_case, name, path, index)
    where = "suite '#{name}' case #{index + 1} (#{path})"
    raise Error, "#{where} is not a mapping" unless raw_case.is_a?(Hash)

    id = raw_case['id'].to_s
    raise Error, "#{where} has no id" if id.empty?

    acceptance = raw_case['acceptance'].to_s.strip
    raise Error, "suite '#{name}' case '#{id}' has no acceptance criterion (#{path})" if acceptance.empty?

    TestCase.new(suite: name, id: id, tags: string_list(raw_case['tags']), acceptance: acceptance,
                 retries: retries(raw_case['retries']), steps: steps(raw_case['steps'], name, id, path))
  end

  def self.steps(raw_steps, name, id, path)
    where = "suite '#{name}' case '#{id}' (#{path})"
    raise Error, "#{where} has no steps" unless raw_steps.is_a?(Array) && !raw_steps.empty?

    raw_steps.each_with_index { |raw_step, index| check_verb(raw_step, index, where) }
    raw_steps
  end

  # The verb check is structural and runs before the compiler sees the step, so
  # a typo reports as the unknown verb it is rather than as the compiler's own
  # "unknown key" message, which reads like a mistyped option.
  def self.check_verb(raw_step, index, where)
    raise Error, "#{where} step #{index + 1} is not a mapping" unless raw_step.is_a?(Hash)

    keys = raw_step.keys.map(&:to_s)
    verbs = keys & ChangeSuiteSchema::STEP_VERBS
    unknown = keys - ChangeSuiteSchema::STEP_VERBS - ChangeFlowCompiler::OPTION_KEYS
    raise Error, "#{where} step #{index + 1} names unknown step verb(s): #{unknown.sort.join(', ')}" if unknown.any?
    raise Error, "#{where} step #{index + 1} names no step verb" if verbs.empty?
    raise Error, "#{where} step #{index + 1} names more than one step verb: #{verbs.sort.join(', ')}" if verbs.size > 1
  end

  def self.retries(value)
    count = value.to_i
    count.positive? ? count : 0
  end

  def self.string_list(value) = Array(value).map(&:to_s).reject(&:empty?)
end

# Every suite a lane's `suites:` globs resolve to, loaded once.
#
# Load failures are collected rather than raised, so `doctor` can report every
# broken suite in one pass instead of one per run, and so the lane can turn each
# into its own failing finding. A glob matching nothing is one of those
# failures: a suite list that silently resolves to zero cases is how a gate
# stops checking anything without anyone noticing.
class ChangeSuiteSet
  attr_reader :suites, :errors

  def self.load(globs, dir)
    suites = []
    errors = []
    Array(globs).map(&:to_s).reject(&:empty?).each do |glob|
      matches = Dir.glob(File.expand_path(glob, dir.to_s)).select { |path| File.file?(path) }.sort
      next errors << "suites glob matched no readable file: #{glob}" if matches.empty?

      matches.each do |path|
        suites << ChangeSuite.load_file(path)
      rescue ChangeSuite::Error => e
        errors << e.message
      end
    end
    new(suites, errors)
  end

  def initialize(suites, errors)
    @suites = suites
    @errors = errors
  end

  def cases = @suites.flat_map(&:cases)

  def empty? = cases.empty?

  # The cases a `tags:` filter selects, in suite-then-file order so a report's
  # case sequence is stable across runs.
  #
  # An explicit `--suite` selector list wins outright over the configured
  # `tags:` rather than intersecting with it: a person asking for one suite by
  # name is narrowing the run themselves, and silently re-applying the config's
  # filter on top would answer a question they did not ask.
  def selected(tags, selectors: [])
    list = Array(selectors).map(&:to_s).reject(&:empty?)
    return cases.select { |item| item.named_by?(list) } unless list.empty?

    cases.select { |item| item.selected?(tags) }
  end

  # `--suite` selectors naming no loaded case. Reported rather than left to
  # surface as an empty run, because "nothing matched" and "nothing to run" look
  # identical from the outside and mean very different things.
  def unmatched_selectors(selectors)
    known = suites.map(&:name) + cases.flat_map(&:tags)
    Array(selectors).map(&:to_s).reject(&:empty?) - known.uniq
  end

  # `gate_tags` entries matching no loaded case. Almost always a typo or a tag
  # that was renamed in the suite and not in CHANGE.md, and its effect is to
  # quietly widen (or, with other entries present, narrow) what can fail the
  # gate, so it is reported rather than ignored.
  def unmatched_gate_tags(gate_tags)
    known = cases.flat_map(&:tags).uniq
    Array(gate_tags).map(&:to_s) - known
  end
end
