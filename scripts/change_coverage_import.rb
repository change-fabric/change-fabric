#!/usr/bin/env ruby
# frozen_string_literal: true

require 'time'
require_relative 'change_coverage_schema'

# Reads the coverage and test-result files a project's own CI already writes
# (Cobertura, JaCoCo, lcov, JUnit, TestNG) into one `imports.coverage[]` or
# `imports.test_results[]` summary of the QA coverage run record.
#
# `ChangeCoverageImport.read` never raises. A glob that matches nothing is
# silent (normal on a laptop that has not run the build); a file that cannot
# be parsed, has an unknown root element, or is too large is skipped with a
# warning; a file older than the HEAD commit is kept, flagged `stale`, and
# warned about. Imported results describe the client's pipeline, not this run,
# so they never become Findings and never gate.
#
# Cobertura and JaCoCo reports can be tens of megabytes, so they stream
# through REXML's SAX2 parser and never build a DOM. JUnit and TestNG files
# are small per file and parse as a DOM; one over MAX_DOM_BYTES is skipped.
module ChangeCoverageImport
  COVERAGE_FORMATS = %w[cobertura jacoco lcov].freeze
  TEST_FORMATS = %w[junit testng].freeze
  FORMATS = (COVERAGE_FORMATS + TEST_FORMATS).freeze

  MAX_DOM_BYTES = 50 * 1024 * 1024
  # A Cobertura timestamp below this is in seconds, at or above it in
  # milliseconds (10^11 ms is 1973; 10^11 s is far in the future).
  EPOCH_MS_FLOOR = 10**11

  # The per-case record's top-level keys, in CASE_FIELDS order
  # (`quarantine.reason` and friends live under one `quarantine` key).
  CASE_KEYS = ChangeCoverageSchema::CASE_FIELDS.map { |field| field.split('.').first }.uniq.freeze

  # `summary` is one schema-1 import hash, or nil when no file was read.
  Result = Data.define(:summary, :warnings)

  # Raised inside a parser to abandon one file; turned into a warning.
  class Unreadable < StandardError; end

  # `paths` is a glob or a list of globs, resolved against `repo_root`.
  # `head_time` is the HEAD commit time (a Time) or nil to skip staleness.
  def self.read(paths:, format:, label:, repo_root:, head_time:)
    Reader.new(paths:, format: format.to_s, label: (label || format).to_s, repo_root:, head_time:).result
  rescue StandardError => e
    Result.new(summary: nil, warnings: [ "#{label || format}: import failed (#{e.class}: #{e.message})" ])
  end

  # One per-case record carrying exactly CASE_KEYS. Imported cases are never
  # gated, carry no quarantine, and report no reached routes.
  def self.case_record(source:, suite:, id:, status:, attempts: 1, flaky: false, duration_ms: nil, tags: [],
                       message: nil)
    {
      'source' => source, 'suite' => suite, 'id' => id, 'status' => status, 'gated' => nil,
      'attempts' => attempts, 'flaky' => flaky, 'duration_ms' => duration_ms, 'tags' => tags,
      'message' => clip(message), 'acceptance_verdict' => nil, 'quarantine' => nil,
      'gotos_reached' => nil, 'landed_url' => nil
    }
  end

  # Whitespace collapsed and cut to MESSAGE_MAX characters; nil when blank.
  def self.clip(text)
    flat = text.to_s.gsub(/\s+/, ' ').strip
    flat.empty? ? nil : flat[0, ChangeCoverageSchema::MESSAGE_MAX]
  end

  # A `{covered, total}` counter pair, summed across files and groups.
  class Tally
    attr_reader :covered, :total

    def initialize(covered = 0, total = 0)
      @covered = covered
      @total = total
    end

    def add(covered, total)
      @covered += covered
      @total += total
      self
    end

    def absorb(other) = add(other.covered, other.total)

    def to_h = { 'covered' => covered, 'total' => total }

    # Sort key: lowest coverage first, an empty tally last.
    def ratio = total.zero? ? 2r : Rational(covered, total)
  end

  # What one coverage file yields. `branch` is nil when the file reports no
  # branch data; groups map a name to `[line Tally, branch Tally]`.
  CoverageFile = Data.define(:line, :branch, :groups, :timestamp)
  # What one test-result file yields: per-case records and its own timestamp.
  TestFile = Data.define(:cases, :timestamp)

  # Expands the globs, parses each file with the format's parser, and folds
  # the files into one summary.
  class Reader
    def initialize(paths:, format:, label:, repo_root:, head_time:)
      @globs = Array(paths)
      @format = format
      @label = label
      @repo_root = repo_root.to_s
      @head_time = head_time
      @warnings = []
      @stale = false
    end

    def result
      unless FORMATS.include?(@format)
        return Result.new(summary: nil, warnings: [ "#{@label}: unknown import format #{@format.inspect}" ])
      end

      parsed = files.filter_map { |file| parse(file) }
      summary = parsed.empty? ? nil : summarize(parsed)
      Result.new(summary:, warnings: @warnings)
    end

    private

    def files
      @globs.flat_map { |glob| Dir.glob(glob.to_s, base: @repo_root).sort }.uniq
    end

    def absolute(file) = File.expand_path(file, @repo_root)

    # `[file, parsed]`, or nil after a warning.
    def parse(file)
      path = absolute(file)
      return nil unless File.file?(path)

      parsed = parser.parse(path)
      parsed = parsed.with(timestamp: parsed.timestamp || File.mtime(path).utc)
      check_stale(file, parsed.timestamp)
      [ file, parsed ]
    rescue LoadError => e
      @warnings << "#{@label}: #{file} skipped, XML support unavailable (#{e.message})"
      nil
    rescue Unreadable => e
      @warnings << "#{@label}: #{file} skipped, #{e.message}"
      nil
    rescue StandardError => e
      @warnings << "#{@label}: #{file} could not be parsed (#{e.class}: #{first_line(e.message)})"
      nil
    end

    def parser
      case @format
      when 'cobertura' then CoberturaParser.new
      when 'jacoco' then JacocoParser.new
      when 'lcov' then LcovParser.new(@repo_root)
      when 'junit' then JunitParser.new
      when 'testng' then TestngParser.new
      end
    end

    def check_stale(file, timestamp)
      return unless @head_time && timestamp < @head_time

      @stale = true
      @warnings << "#{@label}: #{file} predates HEAD"
    end

    def first_line(text) = text.to_s.lines.first.to_s.strip

    def summarize(parsed)
      base = { 'label' => @label, 'format' => @format }
      body = COVERAGE_FORMATS.include?(@format) ? coverage_summary(parsed) : test_summary(parsed)
      # The oldest file names the summary's time, so `stale` and `timestamp`
      # agree: one stale file makes the summary stale.
      oldest = parsed.map { |_, data| data.timestamp }.min
      base.merge(body, 'timestamp' => oldest.utc.iso8601, 'stale' => @stale)
    end

    def coverage_summary(parsed)
      line = Tally.new
      branch = nil
      groups = Hash.new { |hash, name| hash[name] = [ Tally.new, Tally.new ] }
      parsed.each do |_, data|
        line.absorb(data.line)
        branch = (branch || Tally.new).absorb(data.branch) if data.branch
        data.groups.each do |name, (group_line, group_branch)|
          groups[name][0].absorb(group_line)
          groups[name][1].absorb(group_branch)
        end
      end
      file = parsed.size == 1 ? parsed.first[0] : @globs.join(', ')
      {
        'file' => file, 'line' => line.to_h, 'branch' => branch&.to_h,
        'groups' => group_rows(groups, with_branch: !branch.nil?),
        'groups_truncated' => groups.size > ChangeCoverageSchema::MAX_GROUPS
      }
    end

    # Lowest line coverage first, capped; a group's branch counts are null
    # when the file reports no branch data at all.
    def group_rows(groups, with_branch:)
      ranked = groups.sort_by { |name, (group_line, _)| [ group_line.ratio, name ] }
      ranked.first(ChangeCoverageSchema::MAX_GROUPS).map do |name, (group_line, group_branch)|
        { 'name' => name, 'line' => group_line.to_h, 'branch' => with_branch ? group_branch.to_h : nil }
      end
    end

    def test_summary(parsed)
      cases = parsed.flat_map { |_, data| data.cases }
      counts = %w[pass fail error skip].to_h { |status| [ status, cases.count { |item| item['status'] == status } ] }
      counts['flaky'] = cases.count { |item| item['flaky'] }
      # Plain passes are counted, never listed: a green client suite runs to
      # tens of thousands of them, and the page lists only the rest.
      listed = cases.reject { |item| item['status'] == 'pass' && !item['flaky'] }
      items, truncated = ChangeCoverageSchema.cap_cases(listed, ChangeCoverageSchema::MAX_IMPORT_CASE_ITEMS)
      { 'files' => parsed.map(&:first), 'counts' => counts, 'items' => items, 'truncated' => truncated }
    end
  end

  # Timestamp parsing shared by the parsers.
  module Stamp
    module_function

    # Epoch seconds or milliseconds; nil when not a positive integer.
    def epoch(value)
      text = value.to_s.strip
      return nil unless text.match?(/\A\d+\z/)

      number = text.to_i
      return nil if number.zero?

      number < EPOCH_MS_FLOOR ? Time.at(number).utc : Time.at(Rational(number, 1000)).utc
    end

    # ISO 8601 with or without a zone (no zone reads as UTC), or TestNG's
    # trailing ` UTC`; nil when unparseable.
    def iso(value)
      text = value.to_s.strip.sub(/\s*UTC\z/, 'Z')
      return nil if text.empty?

      text += 'Z' unless text.match?(/(Z|[+-]\d{2}:?\d{2})\z/)
      Time.iso8601(text).utc
    rescue ArgumentError
      nil
    end
  end

  # Shared by the two streaming parsers: runs REXML's SAX2 parser over a file
  # and checks the root element.
  class SaxParser
    def parse(path)
      require 'rexml/parsers/sax2parser'
      File.open(path, 'rb') do |io|
        sax = REXML::Parsers::SAX2Parser.new(io)
        listen(sax)
        sax.parse
      end
      raise Unreadable, 'no root element' unless @root_seen

      finish
    end

    private

    def expect_root(name)
      return if @root_seen

      raise Unreadable, "unknown root element <#{name}>" unless name == root_name

      @root_seen = true
    end

    def attr_int(attrs, name) = attrs[name].to_s[/\A\d+/]&.to_i
  end

  # Cobertura: root `lines-covered`/`lines-valid` and
  # `branches-covered`/`branches-valid` give the totals; an older file with
  # only `line-rate`/`branch-rate` is recomputed from its `<line>` elements.
  # Groups are `<package>` elements, always tallied from their lines (the
  # package element carries rates, not counts). Lines under a `<method>`
  # repeat the class's lines and are not counted.
  class CoberturaParser < SaxParser
    CONDITION = %r{\((\d+)/(\d+)\)}

    def initialize
      @root = {}
      @method_depth = 0
      @package = nil
      @line = Tally.new
      @branch = Tally.new
      @branch_seen = false
      @groups = Hash.new { |hash, name| hash[name] = [ Tally.new, Tally.new ] }
    end

    private

    def root_name = 'coverage'

    def listen(sax)
      sax.listen(:start_element) { |_uri, name, _qname, attrs| start(name, attrs) }
      sax.listen(:end_element, %w[method package]) do |_uri, name, _qname|
        name == 'method' ? @method_depth -= 1 : @package = nil
      end
    end

    def start(name, attrs)
      expect_root(name)
      case name
      when 'coverage' then @root = attrs.dup
      when 'package' then @package = attrs['name'].to_s
      when 'method' then @method_depth += 1
      when 'line' then count_line(attrs) if @method_depth.zero?
      end
    end

    def count_line(attrs)
      covered = attr_int(attrs, 'hits').to_i.positive? ? 1 : 0
      group_line, group_branch = @package && @groups[@package]
      @line.add(covered, 1)
      group_line&.add(covered, 1)
      return unless attrs['branch'] == 'true' && (match = attrs['condition-coverage'].to_s.match(CONDITION))

      @branch_seen = true
      @branch.add(match[1].to_i, match[2].to_i)
      group_branch&.add(match[1].to_i, match[2].to_i)
    end

    def finish
      CoverageFile.new(line: totals('lines') || @line, branch: branch_totals, groups: @groups,
                       timestamp: Stamp.epoch(@root['timestamp']))
    end

    def totals(kind)
      covered = attr_int(@root, "#{kind}-covered")
      valid = attr_int(@root, "#{kind}-valid")
      covered && valid ? Tally.new(covered, valid) : nil
    end

    # A zero total (coverage.py without --branch writes `branches-valid="0"`)
    # is no branch data, so it reads as null, as in the lcov parser.
    def branch_totals
      branch = totals('branches') || (@branch_seen ? @branch : nil)
      branch if branch&.total&.positive?
    end
  end

  # JaCoCo: `<counter type="LINE"|"BRANCH" missed covered>` elements that are
  # direct children of `<report>` give the totals (never summed from
  # packages); direct children of a `<package>` give that group. The
  # `report.dtd` DOCTYPE is read as a declaration and never fetched. The
  # timestamp is the latest `<sessioninfo dump>`.
  class JacocoParser < SaxParser
    COUNTED = { 'LINE' => 0, 'BRANCH' => 1 }.freeze

    def initialize
      @stack = []
      @package = nil
      @totals = []
      @groups = Hash.new { |hash, name| hash[name] = [ Tally.new, Tally.new ] }
      @dump = nil
    end

    private

    def root_name = 'report'

    def listen(sax)
      sax.listen(:start_element) do |_uri, name, _qname, attrs|
        expect_root(name)
        start(name, attrs)
        @stack.push(name)
      end
      sax.listen(:end_element) do |_uri, name, _qname|
        @stack.pop
        @package = nil if name == 'package'
      end
    end

    def start(name, attrs)
      case name
      when 'package' then @package = attrs['name'].to_s
      when 'sessioninfo' then note_dump(attrs['dump'])
      when 'counter' then count(attrs)
      end
    end

    def note_dump(value)
      time = Stamp.epoch(value)
      @dump = [ @dump, time ].compact.max
    end

    def count(attrs)
      slot = COUNTED[attrs['type']]
      return unless slot

      covered = attr_int(attrs, 'covered').to_i
      total = covered + attr_int(attrs, 'missed').to_i
      case @stack.last
      when 'report' then @totals[slot] = Tally.new(covered, total)
      when 'package' then @groups[@package][slot].add(covered, total)
      end
    end

    def finish
      CoverageFile.new(line: @totals[0] || Tally.new, branch: @totals[1], groups: @groups, timestamp: @dump)
    end
  end

  # lcov tracefile: per `SF:` record, `LF`/`LH` and `BRF`/`BRH` when present,
  # else counted from `DA:` lines (hits above 0) and `BRDA:` entries (a taken
  # of `-` is 0). A group is the source file's directory relative to the repo
  # root. lcov carries no timestamp, so the file mtime stands in.
  class LcovParser
    Record = Struct.new(:dir, :lf, :lh, :brf, :brh, :da, :brda, keyword_init: true)

    def initialize(repo_root)
      @repo_root = File.expand_path(repo_root.to_s)
      @groups = Hash.new { |hash, name| hash[name] = [ Tally.new, Tally.new ] }
      @line = Tally.new
      @branch = Tally.new
      @branch_seen = false
      @records = 0
    end

    def parse(path)
      record = nil
      File.foreach(path, chomp: true) do |raw|
        text = raw.scrub.strip
        if text.start_with?('SF:')
          record = new_record(text.delete_prefix('SF:'))
        elsif text == 'end_of_record'
          close(record) if record
          record = nil
        elsif record
          read_line(record, text)
        end
      end
      close(record) if record
      raise Unreadable, 'no SF: records (not an lcov tracefile)' if @records.zero?

      CoverageFile.new(line: @line, branch: @branch_seen ? @branch : nil, groups: @groups, timestamp: nil)
    end

    private

    def new_record(source)
      Record.new(dir: group_for(source), da: Tally.new, brda: Tally.new)
    end

    def group_for(source)
      dir = File.dirname(File.expand_path(source, @repo_root))
      return '.' if dir == @repo_root
      return dir.delete_prefix("#{@repo_root}/") if dir.start_with?("#{@repo_root}/")

      dir
    end

    def read_line(record, text)
      key, value = text.split(':', 2)
      case key
      when 'LF', 'LH', 'BRF', 'BRH' then record[key.downcase] = value.to_i
      when 'DA' then record.da.add(value.split(',')[1].to_i.positive? ? 1 : 0, 1)
      when 'BRDA' then record.brda.add(value.split(',')[3].to_i.positive? ? 1 : 0, 1)
      end
    end

    def close(record)
      @records += 1
      line = record.lf ? Tally.new(record.lh.to_i, record.lf) : record.da
      branch = record.brf ? Tally.new(record.brh.to_i, record.brf) : record.brda
      @branch_seen ||= branch.total.positive?
      @line.absorb(line)
      @branch.absorb(branch)
      @groups[record.dir][0].absorb(line)
      @groups[record.dir][1].absorb(branch)
    end
  end

  # Shared by the DOM parsers: size cap, parse, root check.
  class DomParser
    def parse(path)
      raise Unreadable, "larger than #{MAX_DOM_BYTES / (1024 * 1024)} MB" if File.size(path) > MAX_DOM_BYTES

      require 'rexml/document'
      root = REXML::Document.new(File.read(path, mode: 'rb')).root
      raise Unreadable, 'no root element' unless root
      raise Unreadable, "unknown root element <#{root.name}>" unless roots.include?(root.name)

      read(root)
    end

    private

    def seconds_to_ms(value)
      text = value.to_s.delete(',').strip
      text.match?(/\A\d+(\.\d+)?\z/) ? (text.to_f * 1000).round : nil
    end

    def children(element, *names) = element.elements.select { |child| names.include?(child.name) }

    def message_of(element) = element && (element.attributes['message'] || element.text)
  end

  # JUnit XML (Surefire, Gradle, pytest and friends): `<testsuites>` or a bare
  # `<testsuite>`, suites possibly nested. `<failure>` is fail, `<error>` is
  # error, `<skipped>` is skip, else pass. Surefire's `<flakyFailure>` /
  # `<flakyError>` mark a passing case flaky; they and `<rerunFailure>` /
  # `<rerunError>` each add one attempt.
  class JunitParser < DomParser
    RERUNS = %w[flakyFailure flakyError rerunFailure rerunError].freeze
    OUTCOMES = { 'failure' => 'fail', 'error' => 'error', 'skipped' => 'skip' }.freeze

    private

    def roots = %w[testsuites testsuite]

    def read(root)
      @cases = []
      @stamps = []
      walk(root, root.name == 'testsuite' ? root : nil)
      TestFile.new(cases: @cases, timestamp: @stamps.compact.max)
    end

    # Depth-first in document order with an explicit stack, so deeply nested
    # suites cannot exhaust the Ruby stack (SystemStackError is not a
    # StandardError and would escape `read`).
    def walk(root, suite)
      stack = [ [ root, suite ] ]
      until stack.empty?
        element, owner = stack.pop
        if element.name == 'testcase'
          @cases << record(element, owner)
        else
          @stamps << Stamp.iso(element.attributes['timestamp']) if element.name == 'testsuite'
          stack.concat(children_to_visit(element, owner).reverse)
        end
      end
    end

    def children_to_visit(element, suite)
      element.elements.filter_map do |child|
        case child.name
        when 'testsuite' then [ child, child ]
        when 'testcase' then [ child, suite ]
        end
      end
    end

    def record(testcase, suite)
      outcome = testcase.elements.find { |child| OUTCOMES.key?(child.name) }
      reruns = children(testcase, *RERUNS)
      status = outcome ? OUTCOMES[outcome.name] : 'pass'
      ChangeCoverageImport.case_record(
        source: 'junit', suite: suite_name(suite, testcase), id: case_id(testcase), status:,
        attempts: 1 + reruns.size, flaky: status == 'pass' && reruns.any?,
        duration_ms: seconds_to_ms(testcase.attributes['time']),
        message: message_of(outcome || reruns.first)
      )
    end

    def suite_name(suite, testcase) = (suite&.attributes&.[]('name') || testcase.attributes['classname']).to_s

    def case_id(testcase)
      classname = testcase.attributes['classname'].to_s
      name = testcase.attributes['name'].to_s
      classname.empty? ? name : "#{classname}##{name}"
    end
  end

  # TestNG `testng-results.xml`: each `<test-method>` under a `<class name>`,
  # configuration methods (`is-config="true"`) excluded. PASS, FAIL and SKIP
  # map to pass, fail and skip; any other status reads as fail. Groups come
  # from a method's own `<groups>` or the suite-level `<groups>` index.
  class TestngParser < DomParser
    STATUSES = { 'PASS' => 'pass', 'FAIL' => 'fail', 'SKIP' => 'skip' }.freeze

    private

    def roots = %w[testng-results]

    def read(root)
      @cases = []
      @stamps = []
      root.each_element('suite') { |suite| read_suite(suite) }
      TestFile.new(cases: @cases, timestamp: @stamps.compact.max)
    end

    def read_suite(suite)
      @stamps << Stamp.iso(suite.attributes['started-at'])
      groups = suite_groups(suite)
      suite.each_element('test/class') do |klass|
        name = klass.attributes['name'].to_s
        klass.each_element('test-method') do |method|
          next if method.attributes['is-config'] == 'true'

          @cases << record(name, method, groups)
        end
      end
    end

    # `{"class#method" => [group, ...]}` from `<suite><groups><group name>
    # <method class name/>`.
    def suite_groups(suite)
      index = Hash.new { |hash, key| hash[key] = [] }
      suite.each_element('groups/group') do |group|
        group.each_element('method') do |method|
          index["#{method.attributes['class']}##{method.attributes['name']}"] << group.attributes['name'].to_s
        end
      end
      index
    end

    def record(klass, method, groups)
      id = "#{klass}##{method.attributes['name']}"
      own = method.get_elements('groups/group').map { |group| group.attributes['name'].to_s }
      ChangeCoverageImport.case_record(
        source: 'testng', suite: klass, id:, status: STATUSES.fetch(method.attributes['status'].to_s, 'fail'),
        duration_ms: method.attributes['duration-ms'].to_s[/\A\d+\z/]&.to_i,
        tags: (own + groups.fetch(id, [])).uniq, message: exception_message(method)
      )
    end

    def exception_message(method)
      exception = method.elements['exception']
      return nil unless exception

      text = exception.elements['message']&.text
      text.to_s.strip.empty? ? exception.attributes['class'] : text
    end
  end
end
