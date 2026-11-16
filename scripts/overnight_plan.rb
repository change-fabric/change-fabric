#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require_relative 'change_frontmatter'
require_relative 'change_policy'
require_relative 'overnight_store'

# cf:overnight intake and dry-run. Resolves a typed capability manifest from
# the repo's own files, each field carrying its value, its source (file:line
# or `default`) and its precedence rank: CHANGE.md frontmatter > AGENTS.md >
# CLAUDE.md > docs > planner default. Prose files declare a field with one
# line `overnight.<field>: <value>`; CHANGE.md contributes only what its
# frontmatter already states (trunk, production tag rule, production lanes).
#
# A safety field that is missing, or that two sources state differently, is a
# capability denial for every step needing it, never a guess.
#
# The dry-run path is non-executing by construction: it builds no executor
# (none exists before the enablement gate) and its only process calls go
# through ReadOnlyDiscovery, which refuses anything outside the read-only
# allowlist. Output is byte-stable: no clock, sorted keys, repo-relative paths.
module OvernightPlan
  # name => [type, safety?, default]. A safety field never takes a default.
  FIELDS = {
    'trunk_model' => [ :string, false, 'main' ],
    'staging_trigger' => [ :string, false, 'merge to trunk' ],
    'staging_workflow' => [ :string, false, nil ],
    'production_trigger' => [ :string, false, nil ],
    'production_workflow' => [ :string, false, nil ],
    'version_endpoint' => [ :string, false, nil ],
    'agent_tags_allowed' => [ :bool, true, nil ],
    'production_lanes' => [ :list, true, nil ],
    'flags_adapter' => [ :string, true, nil ],
    'terraform_wrapper' => [ :string, true, nil ],
    'migration_command' => [ :string, true, nil ],
    'expand_only_marker' => [ :string, true, nil ],
    'maintenance_command' => [ :string, true, nil ],
    'backup_provider' => [ :string, true, nil ],
    'credential_isolation' => [ :bool, true, nil ],
    'readonly_data_access' => [ :string, false, 'none' ],
    'day_goals_path' => [ :string, false, 'reports/overnight-<date>.md' ]
  }.freeze

  SAFETY = FIELDS.select { |_, (_, safety, _)| safety }.keys.freeze

  # Capability => the fields it needs. A denied field denies the capability.
  CAPABILITIES = {
    'production-tag' => %w[agent_tags_allowed production_lanes],
    'flags' => %w[flags_adapter],
    'terraform' => %w[terraform_wrapper],
    'migrations' => %w[migration_command expand_only_marker],
    'destructive' => %w[backup_provider maintenance_command credential_isolation migration_command expand_only_marker]
  }.freeze

  # Schedule step => manifest fields it depends on. A policy hash change
  # invalidates every not-yet-dispatched step whose fields changed.
  STEP_FIELDS = {
    'build' => %w[trunk_model],
    'local-ci' => [],
    'review-gate' => [],
    'change-gate' => [],
    'merge' => %w[trunk_model],
    'staging-deploy' => %w[staging_trigger staging_workflow],
    'staging-version' => %w[version_endpoint],
    'staging-smoke' => %w[flags_adapter],
    'production-tag' => %w[agent_tags_allowed production_lanes production_trigger],
    'production-deploy' => %w[production_workflow],
    'production-version' => %w[version_endpoint],
    'smoke-flag-off' => %w[flags_adapter],
    'smoke-flag-on' => %w[flags_adapter],
    'smoke-flag-off-again' => %w[flags_adapter],
    'flag-final' => %w[flags_adapter],
    'healthy' => %w[version_endpoint]
  }.freeze

  RISKY_PRODUCTION_LANES = %w[k6 zap].freeze
  MODES = %w[local-only merge-ready admin-bypass yolo].freeze
  DEADLINES = { 'discovery' => 10, 'deploy' => 45, 'smoke' => 15 }.freeze
  WALKTHROUGH_RESERVATION = { 'roast' => 2.0, 'render' => 1.0 }.freeze
  DECLARATION = /^\s*overnight\.([a-z_]+):\s*(.+?)\s*$/
  SECRET_PATTERNS = [
    [ /\b([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY|KEY))=\S+/, '\1=****' ],
    [ /\b(?:ghp_|gho_|ghs_|github_pat_|sk-|xox[abp]-)[A-Za-z0-9_-]+/, '****' ]
  ].freeze

  INTERVIEW = [
    [ 'Destructive writes', 'full guard (verified backup, test restore, snapshot, window) | never | staging only' ],
    [ 'Scope and order', 'the schedule below | a subset | a different order' ],
    [ 'Flag after ship', 'on | off | as the plan says' ],
    [ 'Walkthrough', 'numbered drafts overnight, final in the morning | none' ]
  ].freeze

  # Runs only the read-only discovery commands the plan names. Anything else
  # raises before a process starts.
  class ReadOnlyDiscovery
    ALLOWED = [
      %w[git log], %w[git worktree list], %w[git ls-remote], %w[gh pr list], %w[gh run list]
    ].freeze

    class Refused < StandardError; end

    def initialize(repo, runner: nil)
      @repo = repo
      @runner = runner || ->(argv) { Open3.capture2(*argv, chdir: @repo) }
    end

    def self.allowed?(argv) = ALLOWED.any? { |prefix| argv.first(prefix.size) == prefix }

    def run(argv)
      raise Refused, "dry-run refuses #{argv.join(' ')}" unless self.class.allowed?(argv)

      out, status = @runner.call(argv)
      status.respond_to?(:success?) && !status.success? ? '' : out.to_s
    rescue SystemCallError
      ''
    end

    # Discovery runs only at a repo's own top level, so a fixture directory
    # nested in another checkout never reads the enclosing repo.
    def git_repo? = File.exist?(File.join(@repo, '.git'))

    def open_prs
      return [] unless git_repo?

      JSON.parse(run(%w[gh pr list --state open --json number,title,headRefName,body --limit 100]).then { |s| s.empty? ? '[]' : s })
    rescue JSON::ParserError
      []
    end

    def worktrees
      return [] unless git_repo?

      run(%w[git worktree list --porcelain]).split("\n\n").filter_map do |block|
        path = block[/^worktree (.+)$/, 1]
        branch = block[%r{^branch refs/heads/(.+)$}, 1]
        { 'path' => path, 'branch' => branch } if path && branch
      end
    end
  end

  module_function

  # --- manifest ------------------------------------------------------------

  def sources(repo)
    docs = Dir.glob(File.join(repo, 'docs', '**', '*.md')).sort
    [ [ 'AGENTS.md', 2 ], [ 'CLAUDE.md', 3 ] ].map { |name, rank| [ File.join(repo, name), rank ] } +
      docs.map { |path| [ path, 4 ] }
  end

  def declarations(repo)
    found = Hash.new { |h, k| h[k] = [] }
    change_declarations(repo).each { |field, decl| found[field] << decl }
    sources(repo).each do |path, rank|
      next unless File.file?(path)

      File.readlines(path, chomp: true).each_with_index do |line, index|
        next unless (m = line.match(DECLARATION))

        found[m[1]] << { 'raw' => m[2], 'source' => "#{relative(repo, path)}:#{index + 1}", 'rank' => rank }
      end
    end
    found
  end

  # What CHANGE.md's frontmatter already states, mapped onto manifest fields.
  def change_declarations(repo)
    path = File.join(repo, 'CHANGE.md')
    return [] unless File.file?(path)

    text = File.read(path)
    front = ChangeFrontmatter.parse(text)
    policy = ChangePolicy.new(front['change_policy'], path)
    out = []
    trunk = front.dig('change_policy', 'gate', 'trunk')
    out << [ 'trunk_model', decl(trunk, text, 'trunk') ] if trunk
    pattern, rule = policy.tag_promotion.find { |p, r| policy.environment_for_rule(r, p) == 'production' }
    return out unless pattern

    out << [ 'production_trigger', decl("tag #{pattern}", text, "tag:#{pattern}") ]
    profile = policy.profile_for_rule(rule)
    lanes = production_lanes(front['change_config'], profile)
    out << [ 'production_lanes', decl(lanes.join(', '), text, profile ? "profile: #{profile}" : 'lanes:') ] if lanes
    out
  end

  def decl(raw, text, key)
    index = text.lines.index { |line| line.include?(key) }
    { 'raw' => raw.to_s, 'source' => "CHANGE.md:#{index ? index + 1 : 1}", 'rank' => 1 }
  end

  def production_lanes(config, profile)
    return nil unless config.is_a?(Hash)

    lanes = profile ? config.dig('profiles', profile, 'lanes') : config['lanes']
    return nil unless lanes.is_a?(Hash)

    lanes.reject { |_, v| v.is_a?(Hash) && v['enabled'] == false }.keys.map(&:to_s).sort
  end

  def coerce(type, raw)
    case type
    when :bool
      return true if raw.match?(/\A(yes|true)\z/i)
      return false if raw.match?(/\A(no|false)\z/i)

      raise ArgumentError, "expected yes or no, got #{raw.inspect}"
    when :list then raw.split(',').map(&:strip).reject(&:empty?).sort
    else raw
    end
  end

  # Field => { value, source, rank, safety } plus a denials list.
  def manifest(repo)
    found = declarations(repo)
    fields = {}
    denials = []
    FIELDS.each do |name, (type, safety, default)|
      decls = found[name].sort_by { |d| [ d['rank'], d['source'] ] }
      begin
        values = decls.map { |d| d.merge('value' => coerce(type, d['raw'])) }
      rescue ArgumentError => e
        fields[name] = { 'value' => nil, 'source' => decls.first['source'], 'safety' => safety }
        denials << { 'field' => name, 'reason' => "invalid: #{e.message}" } if safety
        next
      end
      if values.empty?
        fields[name] = { 'value' => default, 'source' => 'default', 'rank' => 5, 'safety' => safety }
        denials << { 'field' => name, 'reason' => 'missing' } if safety
      elsif safety && values.map { |v| v['value'] }.uniq.size > 1
        fields[name] = { 'value' => nil, 'source' => values.map { |v| v['source'] }.join(' vs '), 'safety' => true }
        denials << { 'field' => name, 'reason' => "conflict: #{values.map { |v| "#{v['source']}=#{v['raw']}" }.join(' vs ')}" }
      else
        top = values.first
        fields[name] = { 'value' => top['value'], 'source' => top['source'], 'rank' => top['rank'], 'safety' => safety }
      end
    end
    { 'fields' => fields, 'denials' => denials, 'capabilities' => capabilities(fields, denials) }
  end

  # Capability => nil when available, else the reasons it is denied.
  def capabilities(fields, denials)
    denied = denials.map { |d| d['field'] }
    CAPABILITIES.to_h do |cap, needs|
      reasons = needs.select { |f| denied.include?(f) }.map { |f| "#{f} #{denials.find { |d| d['field'] == f }['reason'].split(':').first}" }
      reasons.concat(value_denials(cap, fields))
      [ cap, reasons.empty? ? nil : reasons ]
    end
  end

  def value_denials(cap, fields)
    value = ->(name) { fields.dig(name, 'value') }
    case cap
    when 'production-tag'
      out = []
      out << 'repo forbids agent tags' if value['agent_tags_allowed'] == false
      risky = Array(value['production_lanes']) & RISKY_PRODUCTION_LANES
      out << "production profile runs #{risky.join(' and ')}" unless risky.empty?
      out
    when 'destructive'
      value['credential_isolation'] == false ? [ 'no credential isolation inside the executor' ] : []
    else []
    end
  end

  # --- policy snapshot -----------------------------------------------------

  def policy(manifest, answers)
    { 'fields' => manifest['fields'].transform_values { |f| f['value'] },
      'denials' => manifest['denials'], 'answers' => answers }
  end

  def policy_hash(policy) = OvernightStore.policy_hash(policy)

  def changed_fields(old_policy, new_policy)
    keys = (old_policy['fields'].keys | new_policy['fields'].keys).sort
    keys.reject { |k| old_policy['fields'][k] == new_policy['fields'][k] }
  end

  # Not-yet-dispatched steps that depend on a changed field. `steps` is a list
  # of { 'unit', 'step', 'dispatched' } hashes; dispatched ones are kept.
  def invalidated(steps, changed)
    steps.reject { |s| s['dispatched'] }.select { |s| STEP_FIELDS.fetch(s['step'], []).intersect?(changed) }
  end

  # --- units ---------------------------------------------------------------

  def plan_units(plan_dir)
    path = plan_dir && File.join(plan_dir, 'plan.md')
    return [] unless path && File.file?(path)

    sections = File.read(path).split(/^(?=### P\d+\. )/).grep(/\A### P\d+\. /)
    sections.each_with_index.map do |section, index|
      number, title = section.lines.first.match(/\A### P(\d+)\. (.+)$/).captures
      declared = section[/^depends_on:\s*(.+)$/i, 1]
      deps = declared ? declared.scan(/P(\d+)/i).flatten.map { |n| "p#{n}" } : []
      deps = [ "p#{sections[index - 1][/\A### P(\d+)/, 1]}" ] if declared.nil? && index.positive?
      { 'id' => "p#{number}", 'phase' => number.to_i, 'title' => title.strip, 'depends_on' => deps }
    end
  end

  # Adopts in-flight work: a PR whose title matches the unit's, or whose body
  # carries the unit's plan phase trailer, plus any worktree on its branch.
  def adopt(units, prs, worktrees)
    adopted = units.map do |unit|
      pr = prs.find do |p|
        p['title'].to_s.casecmp?(unit['title']) || p['body'].to_s.match?(/#Phase #{unit['phase']}\b/)
      end
      next unit.merge('origin' => 'new') unless pr

      tree = worktrees.find { |w| w['branch'] == pr['headRefName'] }
      unit.merge('origin' => 'adopted', 'pr' => pr['number'], 'branch' => pr['headRefName'], 'worktree' => tree&.dig('path'))
    end
    used = adopted.filter_map { |u| u['pr'] }
    [ adopted, prs.reject { |p| used.include?(p['number']) }.sort_by { |p| p['number'] } ]
  end

  # --- schedule ------------------------------------------------------------

  def schedule(unit, manifest, mode, protected_trunk)
    f = ->(name) { manifest['fields'].dig(name, 'value') }
    caps = manifest['capabilities']
    trunk = f['trunk_model']
    steps = []
    add = ->(step, command, gate, expect, deadline = nil) { steps << [ step, command, gate, expect, deadline ] }
    build = unit['origin'] == 'adopted' ? "adopt #{unit['branch']} (never rebuilt)" : "git worktree add -b overnight/#{unit['id']} <worktree> origin/#{trunk}"
    add['build', build, 'ON-1 one unit under the fenced lease', 'worktree on the unit branch']
    add['local-ci', '/cf:drive quick --local-only', 'tests and lint green', 'green locally']
    return steps if mode == 'local-only'
    return [ [ 'refused', 'none', 'ON-3', 'yolo refused: the repo protects its trunk', nil ] ] if mode == 'yolo' && protected_trunk

    add['review-gate', 'ruby ~/.claude/cf/bin/review_ack.rb <session_id>', 'review gate released', 'review recorded']
    add['change-gate', 'ruby ~/.claude/cf/bin/change_run.rb all', 'cf:change pass for the head sha', 'gate recorded']
    if mode == 'merge-ready'
      add['merge', 'ruby ~/.claude/cf/bin/stack_watch.rb <pr>', 'ON-3 human merges; SW-2', 'merged tonight or handed over']
    else
      add['merge', 'gh pr merge <pr> --squash --admin --match-head-commit <sha>', 'ON-3 merge mode and SW-2', 'merged at <sha>']
    end
    deploy_steps(add, 'staging', f['staging_workflow'], f['version_endpoint'])
    flag_step(add, 'staging-smoke', '/cf:qa --suite overnight-smoke (flag on, temporary)', caps)
    if caps['production-tag']
      add['production-tag', 'none', 'ON-4 denied', "staging-only: #{caps['production-tag'].join('; ')}"]
      return steps
    end
    add['production-tag', 'ruby ~/.claude/cf/bin/change_run.rb all --for-tag <tag> && git push origin <tag>',
        'ON-4 change_tag_guard.rb', "#{f['production_trigger'] || 'tag <tag>'} at <sha>"]
    deploy_steps(add, 'production', f['production_workflow'], f['version_endpoint'])
    flag_step(add, 'smoke-flag-off', '/cf:qa --suite overnight-smoke (flag off)', caps)
    flag_step(add, 'smoke-flag-on', '/cf:qa --suite overnight-smoke (flag on)', caps)
    flag_step(add, 'smoke-flag-off-again', '/cf:qa --suite overnight-smoke (flag off)', caps)
    flag_step(add, 'flag-final', 'set the agreed-final flag state, then read it back', caps)
    add['healthy', "curl -fsS #{f['version_endpoint'] || '<version endpoint>'}", 'next-unit rule', 'healthy at <sha>']
    steps
  end

  def deploy_steps(add, env, workflow, endpoint)
    wf = workflow || '<undeclared workflow>'
    add["#{env}-deploy", "gh run list --workflow #{wf} --commit <sha> --json databaseId,headSha,status; " \
                         'Monitor gh run watch <id> --exit-status', 'deploy identity matches <sha>', 'run succeeded',
        "discovery #{DEADLINES['discovery']}m, deploy #{DEADLINES['deploy']}m"]
    add["#{env}-version", "curl -fsS #{endpoint || '<undeclared version endpoint>'}", 'ON-10 before any smoke',
        'deployed version equals <sha>']
  end

  def flag_step(add, step, command, caps)
    if caps['flags']
      add[step, 'none', 'flags denied', "skipped: #{caps['flags'].join('; ')}"]
    else
      smoke = step.include?('smoke')
    add[step, command, 'flags adapter tested at intake (planned: set then read back in staging)',
        smoke ? 'pass' : 'read-back equals the agreed-final state', smoke ? "smoke #{DEADLINES['smoke']}m" : nil]
    end
  end

  # --- dry-run -------------------------------------------------------------

  def dry_run(repo:, plan_dir: nil, mode: 'local-only', budget: 5.0, walkthrough: true, discovery: nil)
    raise ArgumentError, "mode must be one of #{MODES.join('|')}" unless MODES.include?(mode)

    discovery ||= ReadOnlyDiscovery.new(repo)
    man = manifest(repo)
    units, unplanned = adopt(plan_units(plan_dir), discovery.open_prs, discovery.worktrees)
    trunk = man['fields'].dig('trunk_model', 'value')
    protected_trunk = ChangePolicy.for_repo(repo)&.protects?(trunk) || false
    answers = INTERVIEW.to_h { |q, _| [ q, 'not asked (dry-run)' ] }
    pol = policy(man, answers)
    lines = []
    lines << '# cf:overnight dry-run'
    lines << "repo: #{repo}"
    lines << "plan: #{plan_dir || 'none'}"
    lines << "mode: #{mode}"
    lines << "execution: disabled (OVERNIGHT_EXECUTE_ENABLED is #{OvernightStore.execute_enabled?}); nothing below runs"
    lines << "policy sha256: #{policy_hash(pol)}"
    lines << '' << '## Manifest'
    man['fields'].each do |name, f|
      lines << "#{name}: #{display(f['value'])} [#{f['source']}]#{' safety' if f['safety']}"
    end
    lines << '' << '## Denials'
    lines << 'none' if man['denials'].empty?
    man['denials'].each { |d| lines << "#{d['field']}: #{d['reason']}" }
    man['capabilities'].each { |cap, reasons| lines << "capability #{cap}: #{reasons ? "denied (#{reasons.join('; ')})" : 'allowed'}" }
    lines << '' << '## Interview (one prompt at run start)'
    INTERVIEW.each do |q, options|
      denied = q == 'Destructive writes' && man['capabilities']['destructive']
      lines << "#{q}: #{denied ? 'never (destructive capability denied for this run)' : options}"
    end
    lines << '' << '## Units'
    lines << 'none' if units.empty?
    units.each do |u|
      extra = u['origin'] == 'adopted' ? " PR ##{u['pr']} #{u['branch']}#{" worktree #{u['worktree']}" if u['worktree']}" : ''
      lines << "#{u['id']} #{u['title']} (#{u['origin']}#{extra}) depends on: #{u['depends_on'].empty? ? 'none' : u['depends_on'].join(', ')}"
    end
    unplanned.each { |p| lines << "in-flight, not adopted: PR ##{p['number']} #{p['headRefName']}" }
    units.each do |u|
      lines << '' << "## Schedule #{u['id']}"
      schedule(u, man, mode, protected_trunk).each_with_index do |(step, command, gate, expect, deadline), i|
        lines << "#{i + 1}. #{step}: #{command}"
        lines << "   gate: #{gate}; expect: #{expect}#{"; deadline: #{deadline}" if deadline}"
      end
    end
    lines << '' << '## Reservations'
    lines.concat(reservations(budget, walkthrough))
    lines << '' << '## Pacing'
    lines << 'Monitor: gh run watch <id> --exit-status per deploy; a Monitor failure falls back to one gh run view <id>'
    lines << 'ScheduleWakeup: fallback every 25 minutes (20 to 30), deduped by a stored next-wake id'
    lines << 'in-session only: a closed session is resumed by a human with /cf:overnight resume <run-id>'
    mask(lines.join("\n") << "\n")
  end

  def reservations(budget, walkthrough)
    return [ "budget: #{format('%.2f', budget)} USD", 'walkthrough: off (--no-walkthrough)' ] unless walkthrough

    total = WALKTHROUGH_RESERVATION.values.sum
    verdict = total <= budget ? 'fits' : 'refused: over budget'
    [ "budget: #{format('%.2f', budget)} USD",
      'cf:walkthrough --estimate-only (free)',
      "cf:walkthrough --draft --none --roast-max-usd #{format('%.2f', WALKTHROUGH_RESERVATION['roast'])} " \
      "--max-usd #{format('%.2f', WALKTHROUGH_RESERVATION['render'])}: reserve #{format('%.2f', total)} USD (#{verdict})",
      'keys: cf_keys.rb status checked at intake, never enrolled in a dry-run' ]
  end

  def display(value)
    case value
    when nil then '(none)'
    when Array then value.join(', ')
    when true then 'yes'
    when false then 'no'
    else value.to_s
    end
  end

  def mask(text) = SECRET_PATTERNS.reduce(text) { |acc, (pattern, repl)| acc.gsub(pattern, repl) }

  def relative(repo, path) = path.delete_prefix("#{repo.chomp('/')}/")

  def main(argv)
    opts = { dry_run: false, repo: Dir.pwd, mode: 'local-only', budget: 5.0, walkthrough: true }
    OptionParser.new do |o|
      o.on('--dry-run') { opts[:dry_run] = true }
      o.on('--repo DIR') { |v| opts[:repo] = v }
      o.on('--plan DIR') { |v| opts[:plan] = v }
      o.on('--mode MODE') { |v| opts[:mode] = v }
      o.on('--budget-usd N', Float) { |v| opts[:budget] = v }
      o.on('--no-walkthrough') { opts[:walkthrough] = false }
    end.parse!(argv)
    unless opts[:dry_run]
      OvernightStore.assert_execute_enabled!
      warn 'only --dry-run is implemented'
      return 2
    end
    print dry_run(repo: opts[:repo], plan_dir: opts[:plan], mode: opts[:mode], budget: opts[:budget],
                  walkthrough: opts[:walkthrough])
    0
  rescue OvernightStore::Disabled, ArgumentError, OptionParser::ParseError => e
    warn e.message
    3
  end
end

exit OvernightPlan.main(ARGV) if $PROGRAM_NAME == __FILE__
