#!/usr/bin/env ruby
# frozen_string_literal: true

require 'uri'
require 'time'
require_relative 'change_schema'
require_relative 'change_coverage_schema'
require_relative 'change_git_context'
require_relative 'change_suite'
require_relative 'change_lane_browserless'

# Builds one QA coverage run record (ChangeCoverageSchema, run schema 1) from
# what a change run already produced: the resolved config, the lanes that ran,
# their findings, the testcases lane's per-case records, and the suite files.
#
# Pure: nothing here runs a lane, a browser or git. The only I/O is whatever
# the caller already did, plus reading suite files through ChangeSuiteSet,
# which is the same strict loader the lane uses. Steps are read raw, never
# through the flow compiler, because compiling a `fill` resolves env values and
# a coverage record must never be able to carry one.
#
# A family the run did not measure is nil (JSON null), never zeros: a lane that
# did not run did not find "0 routes", and the page reads null as "not
# reported" instead of a false failure.
module ChangeCoverage
  STATUS_RANK = { 'pass' => 0, 'warn' => 1, 'fail' => 2 }.freeze
  COVERAGE_FORMATS = %w[cobertura jacoco lcov].freeze
  TEST_RESULT_FORMATS = %w[junit testng].freeze

  module_function

  # A run record for a deterministic sweep of one app. `ids` carries `id`,
  # `sweep_id` and `recorded_at`; `git` is ChangeGitContext's hash plus
  # `trunk`; `repo` is `{root, origin}`; `imports` is a list of importer
  # summaries (or nil when nothing was configured or found).
  def snapshot(config:, lanes_ran:, findings:, case_records:, suite_set:, selection:, git:, ids:, toolkit:,
               repo:, imports:, scope: 'all', app: nil, warnings: [])
    ran = Array(lanes_ran).map(&:to_s)
    list = findings.respond_to?(:to_a) ? findings.to_a : Array(findings)
    records = Array(case_records)
    chosen = selection_hash(selection)
    identity(ids:, source: 'change_run', scope:, selection: chosen, profile: config.profile, app:,
             toolkit:, repo:, git:).merge(
      'lanes' => lanes(config, ran, list),
      'routes' => Routes.new(config:, lanes_ran: ran, findings: list, case_records: records, suite_set:,
                             selection: chosen).to_h,
      'cases' => Cases.new(lanes_ran: ran, case_records: records, suite_set:, selection: chosen, config:).to_h,
      'suite_inventory' => Cases.inventory(suite_set),
      'findings' => ran.empty? ? nil : status_counts(list),
      'imports' => imports_family(imports),
      'warnings' => Array(warnings).map(&:to_s)
    )
  end

  # A run recorded from CI result files alone: every toolkit family is null,
  # only `imports` carries data.
  def import_run(summaries:, git:, ids:, toolkit:, repo:, profile: nil, app: nil, warnings: [])
    identity(ids:, source: 'import', scope: 'import', selection: nil, profile:, app:, toolkit:, repo:, git:).merge(
      'lanes' => nil, 'routes' => nil, 'cases' => nil, 'suite_inventory' => nil, 'findings' => nil,
      'imports' => imports_family(summaries), 'warnings' => Array(warnings).map(&:to_s)
    )
  end

  def identity(ids:, source:, scope:, selection:, profile:, app:, toolkit:, repo:, git:)
    { 'schema' => ChangeCoverageSchema::RUN_SCHEMA, 'id' => pick(ids, :id).to_s,
      'sweep_id' => pick(ids, :sweep_id)&.to_s, 'recorded_at' => timestamp(pick(ids, :recorded_at)),
      'source' => source, 'scope' => scope.to_s, 'selection' => selection, 'profile' => profile&.to_s,
      'app' => app&.to_s, 'toolkit' => toolkit&.to_s, 'repo' => repo_hash(repo), 'git' => git_hash(git) }
  end

  def lanes(config, ran, findings)
    results = ran.to_h do |lane|
      [ lane, lane_result(findings.select { |finding| finding.lane == lane }) ]
    end
    { 'configured' => ChangeSchema::LANES.dup, 'enabled' => config.enabled_lanes, 'ran' => ran,
      'results' => results }
  end

  def lane_result(rows)
    severities = rows.reject(&:pass?).group_by { |row| row.severity.empty? ? 'unspecified' : row.severity }
    { 'status' => worst(rows.map(&:status)) || 'pass', 'findings' => status_counts(rows),
      'by_severity' => severities.sort.to_h { |severity, list| [ severity, list.size ] } }
  end

  def status_counts(rows) = %w[pass warn fail].to_h { |status| [ status, rows.count { |row| row.status == status } ] }

  # The worst of a list of pass/warn/fail statuses, or nil for an empty list.
  def worst(statuses)
    statuses.select { |status| STATUS_RANK.key?(status) }.max_by { |status| STATUS_RANK.fetch(status) }
  end

  def imports_family(summaries)
    list = Array(summaries).map { |summary| summary.to_h.transform_keys(&:to_s).except('warnings') }
    return nil if list.empty?

    { 'coverage' => list.select { |summary| COVERAGE_FORMATS.include?(summary['format'].to_s) },
      'test_results' => list.select { |summary| TEST_RESULT_FORMATS.include?(summary['format'].to_s) } }
  end

  def selection_hash(selection)
    raw = selection || {}
    { 'suites' => Array(pick(raw, :suites)).map(&:to_s), 'tags' => Array(pick(raw, :tags)).map(&:to_s) }
  end

  # The cases this run selected, by the lane's own rule: an explicit `--suite`
  # selector wins outright, else the selection's tags, else the lane's.
  def selected_cases(suite_set, config, selection)
    return [] unless suite_set

    tags = selection['tags']
    tags = Array(config.lane('testcases')['tags']).map(&:to_s).reject(&:empty?) if tags.empty?
    suite_set.selected(tags, selectors: selection['suites'])
  end

  def repo_hash(repo)
    return nil unless repo

    { 'root' => tilde(pick(repo, :root)), 'origin' => ChangeGitContext.sanitize_url(pick(repo, :origin)) }
  end

  def git_hash(git)
    return nil unless git

    pr = pick(git, :pr)
    { 'branch' => pick(git, :branch), 'sha' => pick(git, :sha), 'short_sha' => pick(git, :short_sha),
      'subject' => pick(git, :subject),
      'pr' => pr ? { 'number' => pick(pr, :number), 'url' => pick(pr, :url) } : nil,
      'trunk' => pick(git, :trunk) }
  end

  # The home prefix as `~`, so a committed repo copy carries no home path.
  def tilde(path)
    text = path&.to_s
    return text if text.nil? || text.empty?

    home = Dir.home
    text == home || text.start_with?("#{home}/") ? "~#{text.delete_prefix(home)}" : text
  end

  def timestamp(value) = value.respond_to?(:utc) ? value.utc.iso8601 : value&.to_s

  def pick(hash, key) = hash.key?(key.to_s) ? hash[key.to_s] : hash[key.to_sym]

  # Declared routes against exercised routes, and one cell per lane per route.
  #
  # Declared: `lanes.a11y.routes`, `lanes.browserless.routes` crossed with its
  # viewports, `lanes.zap.targets`, each only when that lane is enabled.
  # Exercised: any lane result for the route, the static `goto` steps and login
  # urls of the cases this run selected, and what the cases reached at run
  # time. Matching is literal on the normalized path; `/claims/123` and
  # `/claims/:id` are different routes.
  class Routes
    DECLARING_LANES = %w[a11y browserless zap].freeze
    ROUTE_LANES = %w[a11y browserless zap testcases].freeze
    ABSOLUTE = %r{\A[a-z][a-z0-9+.\-]*://}i
    RESULT_STATUSES = %w[pass warn fail].freeze

    # A url or path as a route key: no scheme or host (nil when the host is
    # not the target's), no base path (an absolute url under a base with a
    # path prefix like `https://host/app` keeps only the route below it), no
    # query or fragment, no trailing slash except on `/`.
    def self.normalize(url, base_url: nil)
      text = url.to_s.strip
      return nil if text.empty?

      path = text.match?(ABSOLUTE) ? absolute_path(text, base_url) : text.sub(/[?#].*\z/m, '')
      return nil if path.nil?

      path = "/#{path}" unless path.start_with?('/')
      path = path.sub(%r{/+\z}, '')
      path.empty? ? '/' : path
    end

    def self.absolute_path(text, base_url)
      uri = URI.parse(text)
      expected = host_of(base_url)
      return nil if expected && uri.host.to_s.downcase != expected

      below_base(uri.path.to_s, base_url)
    rescue URI::InvalidURIError
      nil
    end

    def self.host_of(url)
      text = url.to_s
      return nil unless text.match?(ABSOLUTE)

      URI.parse(text).host&.downcase
    rescue URI::InvalidURIError
      nil
    end

    # `path` with the base url's own path removed when it starts with it on a
    # path boundary, so `/app/claims` under `https://host/app` is `/claims`
    # and `/app` itself is the root.
    def self.below_base(path, base_url)
      prefix = base_path(base_url)
      return path if prefix.empty?
      return '/' if path == prefix

      path.start_with?("#{prefix}/") ? path.delete_prefix(prefix) : path
    end

    def self.base_path(url)
      text = url.to_s
      return '' unless text.match?(ABSOLUTE)

      URI.parse(text).path.to_s.sub(%r{/+\z}, '')
    rescue URI::InvalidURIError
      ''
    end

    def initialize(config:, lanes_ran:, findings:, case_records:, suite_set:, selection:)
      @config = config
      @ran = lanes_ran
      @findings = findings
      @records = case_records
      @suite_set = suite_set
      @selection = selection
    end

    # nil when no lane that touches routes ran.
    def to_h
      return nil if (@ran & ROUTE_LANES).empty?

      items = paths.map { |path| item(path) }
      exercised = items.select { |entry| exercised?(entry) }
      { 'declared_total' => items.count { |entry| entry['declared'] },
        'declared_exercised' => exercised.count { |entry| entry['declared'] },
        'undeclared_exercised' => exercised.count { |entry| !entry['declared'] },
        'items' => items }
    end

    private

    def paths
      found = declared.keys + reached.keys
      found += static.keys if ran?('testcases')
      found.uniq.sort
    end

    def item(path)
      by = declared.fetch(path, [])
      { 'path' => path, 'declared' => !by.empty?, 'declared_by' => by,
        'viewports' => by.include?('browserless') ? viewport_names : [],
        'lane_status' => ChangeSchema::LANES.to_h { |lane| [ lane, cell(lane, path) ] },
        'cases_static' => static.fetch(path, []), 'cases_reached' => reached.fetch(path, []) }
    end

    def exercised?(entry)
      return true if entry['lane_status'].values.any? { |status| RESULT_STATUSES.include?(status) }
      return true unless entry['cases_reached'].empty?

      ran?('testcases') && static.key?(entry['path'])
    end

    def ran?(lane) = @ran.include?(lane)

    def enabled?(lane) = @config.enabled_lanes.include?(lane)

    def cell(lane, path)
      return 'lane_off' unless ran?(lane)
      return 'n_a' if lane == 'k6'
      return testcases_cell(path) if lane == 'testcases'
      return 'not_declared' unless declared.fetch(path, []).include?(lane)

      ChangeCoverage.worst(lane_statuses.fetch(lane, {}).fetch(path, [])) || 'no_result'
    end

    def testcases_cell(path)
      statuses = reached_statuses.fetch(path, [])
      return ChangeCoverage.worst(statuses) || 'no_result' unless statuses.empty?

      static.key?(path) ? 'no_result' : 'not_declared'
    end

    # --- declared ----------------------------------------------------------------

    def declared
      @declared ||= DECLARING_LANES.select { |lane| enabled?(lane) }.each_with_object({}) do |lane, out|
        declared_paths(lane).each { |path| (out[path] ||= []) << lane unless out.fetch(path, []).include?(lane) }
      end
    end

    def declared_paths(lane)
      base = base_url(lane)
      raw = lane == 'zap' ? zap_targets : route_list(lane)
      raw.filter_map { |entry| Routes.normalize(entry, base_url: base) }.uniq
    end

    def route_list(lane)
      list = Array(@config.lane(lane)['routes']).map { |entry| entry.is_a?(Hash) ? entry['path'].to_s : entry.to_s }
      list = list.reject(&:empty?)
      list.empty? ? ChangeLane::DEFAULT_ROUTES : list
    end

    def zap_targets
      list = Array(@config.lane('zap')['targets']).map(&:to_s).reject(&:empty?)
      list.empty? ? [ base_url('zap') ] : list
    end

    def viewport_names
      raw = @config.lane('browserless')['viewports'] || ChangeLaneBrowserless::DEFAULT_VIEWPORTS
      Array(raw).filter_map { |viewport| viewport.is_a?(Hash) ? viewport['name']&.to_s : nil }
    end

    def base_url(lane) = @config.lane(lane).base_url(@config.boot.target_url)

    # --- lane results --------------------------------------------------------------

    # Statuses per lane per route, keyed the way each lane writes its findings:
    # a11y and browserless name the route in `location` (a11y appends the
    # offending selectors after a space), zap names the scanned url as `target`.
    def lane_statuses
      @lane_statuses ||= @findings.each_with_object({}) do |finding, out|
        path = finding_route(finding)
        next unless path

        ((out[finding.lane] ||= {})[path] ||= []) << finding.status
      end
    end

    def finding_route(finding)
      case finding.lane
      when 'a11y' then Routes.normalize(finding.location.split(/\s+/).first, base_url: base_url('a11y'))
      when 'browserless' then Routes.normalize(finding.location, base_url: base_url('browserless'))
      when 'zap' then Routes.normalize(finding.target, base_url: base_url('zap'))
      end
    end

    # --- test cases ----------------------------------------------------------------

    # Route to the ids of the selected cases whose own steps go there, plus the
    # lane's login urls (reached by every case behind the login, so no ids).
    def static
      @static ||= begin
        out = {}
        login_urls.each { |path| out[path] ||= [] }
        ChangeCoverage.selected_cases(@suite_set, @config, @selection).each do |item|
          static_gotos(item).each { |path| (out[path] ||= []) << item.qualified_id }
        end
        out.transform_values(&:uniq)
      end
    end

    def static_gotos(item)
      base = base_url('testcases')
      Array(item.steps).filter_map do |step|
        next unless step.is_a?(Hash) && step.key?('goto')

        value = step['goto']
        Routes.normalize(value.is_a?(Hash) ? value['url'] : value, base_url: base)
      end.uniq
    end

    def login_urls
      auth = @config.lane('testcases')['auth']
      return [] unless auth.is_a?(Hash)

      urls = [ auth['login_url'] ] + Array(auth['steps']).map { |step| step.is_a?(Hash) ? step['url'] : nil }
      urls.filter_map { |url| Routes.normalize(url, base_url: base_url('testcases')) }.uniq
    end

    # Route to the ids of the cases that reached it at run time: a goto that
    # succeeded, or the page a passing case ended on.
    def reached
      @reached ||= @records.each_with_object({}) do |record, out|
        record_paths(record).each { |path| (out[path] ||= []) << record['id'] }
      end
    end

    def reached_statuses
      @reached_statuses ||= @records.each_with_object({}) do |record, out|
        status = record['status'] == 'error' ? 'fail' : record['status']
        record_paths(record).each { |path| (out[path] ||= []) << status }
      end
    end

    def record_paths(record) = (Array(record['gotos_reached']) + [ record['landed_url'] ]).compact.uniq
  end

  # The test-case family: counts across every per-case record, the records
  # themselves up to a cap, and how many cases exist against how many ran, so
  # a case the selection left out is never read as uncovered.
  class Cases
    COUNT_KEYS = %w[pass fail error skip warn flaky quarantined ungated].freeze

    # Every defined case, selected or not, or nil without a suite set.
    def self.inventory(suite_set)
      return nil unless suite_set

      suite_set.cases.map { |item| { 'suite' => item.suite, 'id' => item.qualified_id, 'tags' => item.tags } }
    end

    def initialize(lanes_ran:, case_records:, suite_set:, selection:, config:)
      @ran = lanes_ran
      @records = case_records
      @suite_set = suite_set
      @selection = selection
      @config = config
    end

    # nil when the testcases lane did not run.
    def to_h
      return nil unless @ran.include?('testcases')

      cap = ChangeCoverageSchema::MAX_CASE_ITEMS
      { 'defined_total' => @suite_set ? @suite_set.cases.size : @records.size,
        'selected_total' => @suite_set ? ChangeCoverage.selected_cases(@suite_set, @config, @selection).size : @records.size,
        'counts' => counts, 'items' => @records.first(cap), 'truncated' => @records.size > cap }
    end

    private

    def counts
      tally = COUNT_KEYS.to_h { |key| [ key, 0 ] }
      @records.each do |record|
        tally[record['status']] += 1 if tally.key?(record['status'])
        tally['flaky'] += 1 if record['flaky'] == true
        tally['ungated'] += 1 if record['gated'] == false
        tally['quarantined'] += 1 if live_quarantine?(record)
      end
      tally
    end

    def live_quarantine?(record)
      quarantine = record['quarantine']
      quarantine.is_a?(Hash) && quarantine['expired'] != true
    end
  end
end
