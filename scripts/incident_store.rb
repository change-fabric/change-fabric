#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require 'open3'

# Durable record of one production incident, kept OUTSIDE git. The store lives
# at ~/.claude/cf/incidents/<repo>/<YYYY-MM-DD-slug>/ (override with
# CF_INCIDENTS_DIR) and refuses any root inside a git work tree, so an RCA can
# never land in a consumer repo. It records; it never runs a prod command and
# never grants an approval: `approved_by` is whatever the human reported.
#
# Layout: incident.json, timeline.md (append-only), ops.json, rca.md, evidence/.
# Timestamps always come from the caller (`--at`, ISO 8601), so tests inject
# them. Every write is atomic (temp file plus rename).
class IncidentStore
  SCHEMA = 'cf.incident-1'
  SEVERITIES = %w[sev1 sev2 sev3].freeze
  SERVING_SOURCES = %w[deploy_api version_endpoint].freeze
  PROBE_RESULTS = %w[pass fail inconclusive auth_failure].freeze
  INCONCLUSIVE = %w[inconclusive auth_failure].freeze
  OP_KINDS = %w[rollback redeploy tag other].freeze
  OP_VIAS = %w[runbook prod_runner].freeze
  GIT_VARS = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY].freeze

  # from => allowed to. `set` cannot jump states.
  STATUS_FLOW = {
    'open' => %w[mitigated fixing],
    'mitigated' => %w[fixing],
    'fixing' => %w[verified unverified],
    'unverified' => %w[fixing verified],
    'verified' => %w[reported],
    'reported' => %w[closed],
    'closed' => []
  }.freeze
  # `close` is its own command, so `set` may not reach it.
  SET_STATUSES = (STATUS_FLOW.keys - %w[closed]).freeze

  OP_FLOW = {
    'drafted' => %w[approved failed],
    'approved' => %w[running],
    'running' => %w[succeeded failed],
    'succeeded' => [],
    'failed' => []
  }.freeze

  HOTFIX_KEYS = %w[pr_url merge_sha fix_version serving_version serving_source].freeze
  PLAIN_KEYS = %w[client severity release_bad release_good probe probe_expected].freeze

  class Invalid < StandardError; end

  attr_reader :root, :repo

  def self.default_root = ENV.fetch('CF_INCIDENTS_DIR', File.join(Dir.home, '.claude', 'cf', 'incidents'))

  def self.segment(value) = value.to_s.strip.gsub(/[^A-Za-z0-9._-]+/, '-').gsub(/\A[-.]+|-+\z/, '')

  # repo_path: the consumer checkout, refused as a store location. Every path in
  # CF_KNOWN_REPO_ROOTS (colon-separated) is refused too.
  def initialize(repo:, root: self.class.default_root, repo_path: nil, known_roots: ENV['CF_KNOWN_REPO_ROOTS'])
    @repo_name = repo.to_s.strip
    @repo = self.class.segment(@repo_name)
    raise Invalid, 'a --repo slug is required' if @repo.empty?

    @root = File.expand_path(root)
    @forbidden = [ repo_path ].compact + known_roots.to_s.split(':').reject(&:empty?)
    self.class.assert_outside_git!(@root, @forbidden, 'incident store')
  end

  # Resolves `path` to its nearest existing ancestor (walking up until a
  # directory exists, so a root that does not exist yet is still judged), then
  # refuses a git work tree and any realpath under a known repo root.
  def self.assert_outside_git!(path, known_roots, what)
    full = File.expand_path(path)
    ancestor, tail = nearest_existing(full)
    real = File.join(File.realpath(ancestor), *tail)
    if inside_work_tree?(ancestor)
      raise Invalid, "#{what} #{full} is inside a git work tree; set CF_INCIDENTS_DIR to a directory outside any repo"
    end

    known_roots.each do |known|
      real_known = resolved(known)
      next unless real == real_known || real.start_with?("#{real_known}/")

      raise Invalid, "#{what} #{full} is under the repo root #{known}; an RCA never lives in a consumer repo"
    end
  end

  def self.nearest_existing(full)
    ancestor = full
    tail = []
    until File.directory?(ancestor)
      tail.unshift(File.basename(ancestor))
      parent = File.dirname(ancestor)
      break if parent == ancestor

      ancestor = parent
    end
    [ ancestor, tail ]
  end

  def self.resolved(path)
    ancestor, tail = nearest_existing(File.expand_path(path))
    File.join(File.realpath(ancestor), *tail)
  end

  def self.inside_work_tree?(dir)
    env = GIT_VARS.to_h { |name| [ name, nil ] }
    out, status = Open3.capture2e(env, 'git', '-C', dir, 'rev-parse', '--is-inside-work-tree')
    return true if status.success? && out.strip == 'true'

    false
  rescue SystemCallError
    marker_above?(dir)
  end

  def self.marker_above?(dir)
    current = File.realpath(dir)
    loop do
      return true if File.exist?(File.join(current, '.git'))

      parent = File.dirname(current)
      return false if parent == current

      current = parent
    end
  end

  # --- commands -------------------------------------------------------------

  def create(slug:, at:, client: nil, severity: 'sev2')
    stamp = time(at)
    clean = self.class.segment(slug.to_s.downcase)
    raise Invalid, 'a --slug is required' if clean.empty?
    raise Invalid, "severity must be one of #{SEVERITIES.join(', ')}" unless SEVERITIES.include?(severity)

    id = "#{stamp.utc.strftime('%Y-%m-%d')}-#{clean}"
    dir = File.join(repo_dir, id)
    guard_dir!(repo_dir, 'repo directory')
    claim_repo_dir!
    guard_dir!(dir, 'incident directory')
    reserve!(dir, id)
    FileUtils.mkdir_p(File.join(dir, 'evidence'))
    write_json(File.join(dir, 'incident.json'), new_record(id, client, severity, at))
    write_json(File.join(dir, 'ops.json'), [])
    File.write(File.join(dir, 'timeline.md'), '')
    append(id, at: at, actor: 'store', text: "incident #{id} opened (#{severity})")
    id
  end

  # An exact id, or a unique prefix, searched only inside this repo's directory.
  def resolve(id)
    wanted = id.to_s.strip
    raise Invalid, 'an --id is required' if wanted.empty?

    names = Dir.exist?(repo_dir) ? Dir.children(repo_dir).select { |n| File.directory?(File.join(repo_dir, n)) } : []
    return wanted if names.include?(wanted)

    hits = names.select { |name| name.start_with?(wanted) }
    raise Invalid, "no incident #{wanted.inspect} for #{@repo}" if hits.empty?
    raise Invalid, "ambiguous incident #{wanted.inspect} for #{@repo}: #{hits.sort.join(', ')}" if hits.size > 1

    hits.first
  end

  def path(id)
    guard_dir!(repo_dir, 'repo directory')
    dir = File.join(repo_dir, resolve(id))
    guard_dir!(dir, 'incident directory')
    dir
  end

  def read(id) = JSON.parse(File.read(File.join(path(id), 'incident.json')))

  def append(id, at:, actor:, text:)
    stamp = time(at)
    line = "- #{stamp.utc.iso8601} #{one_line(actor)}: #{one_line(text)}\n"
    File.open(File.join(path(id), 'timeline.md'), 'a') { |file| file.write(line) }
    line
  end

  # Drafts an op only (status `drafted`); later states go through update_op.
  def record_op(id, kind:, via:, at:, request_id: nil, commands_file: nil)
    raise Invalid, "kind must be one of #{OP_KINDS.join(', ')}" unless OP_KINDS.include?(kind)
    raise Invalid, "via must be one of #{OP_VIAS.join(', ')}" unless OP_VIAS.include?(via)
    raise Invalid, 'via prod_runner needs a --request-id' if via == 'prod_runner' && blank?(request_id)
    raise Invalid, 'via runbook needs a --commands-file' if via == 'runbook' && blank?(commands_file)

    stamp = time(at).utc.iso8601
    op_id = nil
    locked(id) do |dir|
      ops = read_json(File.join(dir, 'ops.json'))
      op_id = "op-#{ops.size + 1}"
      op = { 'op_id' => op_id, 'at' => stamp, 'kind' => kind, 'via' => via, 'status' => 'drafted',
             'approved_by' => nil, 'result' => nil }
      op['request_id'] = request_id if via == 'prod_runner'
      op['commands_file'] = File.expand_path(commands_file) if via == 'runbook'
      write_json(File.join(dir, 'ops.json'), ops + [ op ])
    end
    append(id, at: at, actor: 'store', text: "#{op_id} drafted (#{kind} via #{via})")
    op_id
  end

  def update_op(id, op_id:, status:, at:, approved_by: nil, result: nil, evidence: nil)
    raise Invalid, "status must be one of #{OP_FLOW.keys.join(', ')}" unless OP_FLOW.key?(status)

    stamp = time(at).utc.iso8601
    locked(id) do |dir|
      ops = read_json(File.join(dir, 'ops.json'))
      op = ops.find { |candidate| candidate['op_id'] == op_id } or raise Invalid, "no op #{op_id.inspect} in #{id}"
      check_op_move!(op, status, approved_by, result)
      op.merge!('status' => status, "#{status}_at" => stamp)
      op['approved_by'] = approved_by.to_s.strip if status == 'approved'
      op['result'] = result.to_s.strip if %w[succeeded failed].include?(status)
      (op['evidence'] ||= []) << evidence unless blank?(evidence)
      write_json(File.join(dir, 'ops.json'), ops)
    end
    append(id, at: at, actor: 'store', text: "#{op_id} #{status}#{approved_by ? " (approved by #{approved_by})" : ''}")
  end

  # changes: string keys (see PLAIN_KEYS, HOTFIX_KEYS, status, probe_result,
  # serving_version, serving_source, regression.<name>, hotfix.<key>).
  def set(id, changes, at:)
    stamp = time(at).utc.iso8601
    notes = []
    locked(id) do |dir|
      file = File.join(dir, 'incident.json')
      inc = read_json(file)
      status = changes['status']
      keys = changes.keys - [ 'status' ]
      refuse_frozen_evidence!(inc, keys)
      ordered(keys).each { |key| apply_key(inc, key, changes[key], stamp, notes) }
      status ||= auto_unverified(inc)
      change_status(inc, status, stamp, notes) if status
      write_json(file, inc)
    end
    notes.each { |note| append(id, at: at, actor: 'store', text: note) }
    notes
  end

  def follow_up_add(id, title:, at:, url: nil)
    raise Invalid, 'a follow-up --title is required' if blank?(title)

    count = nil
    locked(id) do |dir|
      file = File.join(dir, 'incident.json')
      inc = read_json(file)
      refuse_closed!(inc)
      item = { 'title' => title.to_s.strip, 'url' => blank?(url) ? nil : url.to_s.strip }
      item['state'] = item['url'] ? 'tracked' : 'drafted'
      inc['follow_ups'] << item
      count = inc['follow_ups'].size
      write_json(file, inc)
    end
    append(id, at: at, actor: 'store', text: "follow-up #{count} added: #{one_line(title)}")
    count
  end

  def follow_up_update(id, n:, at:, url: nil, accepted_untracked: false, by: nil)
    raise Invalid, 'give --url or --accepted-untracked, not both' if !blank?(url) && accepted_untracked
    raise Invalid, 'give --url or --accepted-untracked' if blank?(url) && !accepted_untracked
    raise Invalid, '--accepted-untracked needs --by (the human who accepted)' if accepted_untracked && blank?(by)

    stamp = time(at).utc.iso8601
    locked(id) do |dir|
      file = File.join(dir, 'incident.json')
      inc = read_json(file)
      refuse_closed!(inc)
      item = inc['follow_ups'][n.to_i - 1] if n.to_i.positive?
      raise Invalid, "no follow-up #{n.inspect} in #{id}" unless item

      if accepted_untracked
        item.merge!('state' => 'accepted_untracked', 'accepted_by' => by.to_s.strip, 'accepted_at' => stamp)
      else
        item.merge!('state' => 'tracked', 'url' => url.to_s.strip)
      end
      write_json(file, inc)
    end
    append(id, at: at, actor: 'store', text: "follow-up #{n} #{accepted_untracked ? "accepted untracked by #{by}" : 'tracked'}")
  end

  def close(id, at:)
    stamp = time(at).utc.iso8601
    locked(id) do |dir|
      file = File.join(dir, 'incident.json')
      inc = read_json(file)
      problems = close_problems(inc, dir)
      raise Invalid, "cannot close #{inc['id']}: #{problems.join('; ')}" unless problems.empty?

      inc.merge!('status' => 'closed', 'closed_at' => stamp)
      write_json(file, inc)
    end
    append(id, at: at, actor: 'store', text: 'incident closed')
  end

  private

  def repo_dir = File.join(@root, @repo)

  # Every directory the store writes into is judged by its own realpath, so a
  # checkout or a symlink into one is refused below the root as well.
  def guard_dir!(dir, what) = self.class.assert_outside_git!(dir, @forbidden, what)

  # Two repo names can slug alike (a-b/c and a/b-c), so the first create writes
  # the full name beside the incidents and a different name is refused.
  # Dir.mkdir is atomic: of two sessions creating the same id, one gets EEXIST.
  def reserve!(dir, id)
    Dir.mkdir(dir)
  rescue Errno::EEXIST
    raise Invalid, "incident #{id} already exists for #{@repo}"
  end

  def claim_repo_dir!
    FileUtils.mkdir_p(repo_dir)
    marker = File.join(repo_dir, '.repo')
    File.write(marker, "#{@repo_name}\n") unless File.exist?(marker)
    owner = File.read(marker).strip
    return if owner == @repo_name || !@repo_name.include?('/') || !owner.include?('/')

    raise Invalid, "#{repo_dir} already belongs to #{owner}; #{@repo_name} slugs to the same directory"
  end

  def new_record(id, client, severity, at)
    { 'schema' => SCHEMA, 'id' => id, 'repo' => @repo_name, 'client' => blank?(client) ? nil : client.to_s.strip,
      'status' => 'open', 'severity' => severity, 'detected_at' => time(at).utc.iso8601, 'mitigated_at' => nil,
      'fixed_at' => nil, 'closed_at' => nil, 'release_bad' => nil, 'release_good' => nil,
      'probe' => nil, 'probe_expected' => nil, 'probe_result' => nil, 'regressions' => {},
      'hotfix' => HOTFIX_KEYS.to_h { |key| [ key, nil ] }, 'follow_ups' => [] }
  end

  # Results bind to the serving version, so version fields apply first whatever
  # order the caller gave the flags in.
  def ordered(keys) = keys.partition { |key| !bound_to_version?(key) }.flatten

  def bound_to_version?(key) = key == 'probe_result' || key.start_with?('regression.')

  def evidence_key?(key) = bound_to_version?(key) || %w[probe probe_expected serving_version serving_source hotfix.fix_version
                                                       hotfix.serving_version hotfix.serving_source].include?(key)

  # Once verified, later evidence cannot quietly contradict it: the table has no
  # way back, so a verified incident's evidence is frozen.
  def refuse_frozen_evidence!(inc, keys)
    return unless %w[verified reported closed].include?(inc['status'])

    frozen = keys.select { |key| evidence_key?(key) }
    return if frozen.empty?

    raise Invalid, "#{inc['status']} evidence is frozen; cannot change #{frozen.join(', ')}"
  end

  def apply_key(inc, key, value, stamp, notes)
    case key
    when *PLAIN_KEYS then plain(inc, key, value)
    when 'probe_result' then probe_result(inc, value, stamp, notes)
    when 'serving_version', 'serving_source' then hotfix(inc, key, value)
    when /\Ahotfix\.(.+)\z/ then hotfix(inc, Regexp.last_match(1), value)
    when /\Aregression\.(.+)\z/ then regression(inc, Regexp.last_match(1), value, notes)
    else raise Invalid, "unknown key #{key.inspect}"
    end
  end

  def plain(inc, key, value)
    raise Invalid, "severity must be one of #{SEVERITIES.join(', ')}" if key == 'severity' && !SEVERITIES.include?(value)

    # A result belongs to the check that produced it; a changed check voids it.
    inc['probe_result'] = nil if %w[probe probe_expected].include?(key) && inc[key] != value.to_s.strip
    inc[key] = value.to_s.strip
  end

  def hotfix(inc, key, value)
    raise Invalid, "unknown hotfix field #{key.inspect}" unless HOTFIX_KEYS.include?(key)
    if key == 'serving_source' && !SERVING_SOURCES.include?(value)
      raise Invalid, "serving_source must be one of #{SERVING_SOURCES.join(', ')} (a tag alone never establishes it)"
    end

    inc['hotfix'][key] = value.to_s.strip
  end

  def regression(inc, name, value, notes)
    raise Invalid, "regression #{name} must be pass or fail" unless %w[pass fail].include?(value)

    inc['regressions'][name] = { 'result' => value, 'serving_version' => inc['hotfix']['serving_version'] }
    notes << "regression #{name} #{value}"
  end

  # The pass is bound to the version serving when it was recorded, so a probe
  # that passed on the rolled-back version cannot count for the fix.
  def probe_result(inc, value, stamp, notes)
    raise Invalid, "probe_result must be one of #{PROBE_RESULTS.join(', ')}" unless PROBE_RESULTS.include?(value)
    raise Invalid, 'record the probe (--probe) at triage before its result' if blank?(inc['probe'])

    inc['probe_result'] = { 'result' => value, 'serving_version' => inc['hotfix']['serving_version'], 'at' => stamp }
    notes << "probe #{value} while serving #{inc['hotfix']['serving_version'] || 'unknown'}"
  end

  # Inconclusive evidence, including an auth failure, is `unverified`, which the
  # skill treats as a page to Patrick.
  def auto_unverified(inc)
    result = inc.dig('probe_result', 'result')
    'unverified' if inc['status'] == 'fixing' && INCONCLUSIVE.include?(result)
  end

  def change_status(inc, target, stamp, notes)
    current = inc['status']
    raise Invalid, 'use the close command to close an incident' if target == 'closed'
    raise Invalid, "unknown status #{target.inspect}" unless SET_STATUSES.include?(target)
    return if target == current

    unless STATUS_FLOW.fetch(current, []).include?(target)
      allowed = STATUS_FLOW.fetch(current, []).join(', ')
      raise Invalid, "status #{current} cannot go to #{target} (allowed: #{allowed.empty? ? 'none' : allowed})"
    end
    verify!(inc) if target == 'verified'
    inc['status'] = target
    inc['mitigated_at'] = stamp if target == 'mitigated'
    mark_verified(inc, stamp) if target == 'verified'
    notes << "status #{current} -> #{target}"
  end

  def mark_verified(inc, stamp)
    inc['fixed_at'] = stamp
    inc['verified_at'] = stamp
    # Real clock: close compares it with the RCA file's mtime.
    inc['verified_mark'] = Time.now.to_f
  end

  def refuse_closed!(inc)
    raise Invalid, "#{inc['id']} is closed; open a new incident instead" if inc['status'] == 'closed'
  end

  def verify!(inc)
    problems = verified_problems(inc)
    raise Invalid, "verified refused: #{problems.join('; ')}" unless problems.empty?
  end

  def verified_problems(inc)
    hot = inc['hotfix']
    fix = hot['fix_version']
    found = []
    found << 'no triage probe recorded' if blank?(inc['probe'])
    found << 'hotfix.fix_version not recorded' if blank?(fix)
    found << 'serving_version needs --serving-source deploy_api or version_endpoint' unless SERVING_SOURCES.include?(hot['serving_source'])
    found << "serving_version #{hot['serving_version'].inspect} does not equal fix_version" if blank?(hot['serving_version']) || hot['serving_version'] != fix
    found.concat(probe_problems(inc['probe_result'], fix))
    found.concat(regression_problems(inc['regressions'], fix))
    found
  end

  def probe_problems(result, fix)
    return [ 'probe has not passed since the fix' ] unless result && result['result'] == 'pass'
    return [] if result['serving_version'] == fix

    [ "probe passed while serving #{result['serving_version'].inspect}, not the fix" ]
  end

  # Each row passed while serving the fix, or it does not count.
  def regression_problems(rows, fix)
    return [ 'no P0 regression rows recorded' ] if rows.empty?

    failing = rows.reject { |_, row| row['result'] == 'pass' }.keys
    stale = rows.select { |_, row| row['result'] == 'pass' && row['serving_version'] != fix }.keys
    found = []
    found << "P0 regression rows not passing: #{failing.sort.join(', ')}" unless failing.empty?
    found << "P0 regression rows passed on a version other than the fix: #{stale.sort.join(', ')}" unless stale.empty?
    found
  end

  def close_problems(inc, dir)
    found = []
    found << "status is #{inc['status']}, not reported" unless inc['status'] == 'reported'
    open_items = inc['follow_ups'].each_with_index.select { |item, _| item['state'] == 'drafted' }
    found << "follow-ups not tracked or accepted: #{open_items.map { |_, index| index + 1 }.join(', ')}" unless open_items.empty?
    missing = %w[pr_url merge_sha serving_version].select { |key| blank?(inc['hotfix'][key]) }
    found << "hotfix fields not recorded: #{missing.join(', ')}" unless missing.empty?
    found.concat(rca_problems(inc, dir))
  end

  def rca_problems(inc, dir)
    rca = File.join(dir, 'rca.md')
    return [ 'rca.md does not exist' ] unless File.file?(rca)
    return [] unless inc['verified_mark'] && File.mtime(rca).to_f <= inc['verified_mark'].to_f

    [ 'rca.md was not updated after the verified transition' ]
  end

  def check_op_move!(op, status, approved_by, result)
    unless OP_FLOW.fetch(op['status']).include?(status)
      allowed = OP_FLOW.fetch(op['status']).join(', ')
      raise Invalid, "#{op['op_id']} is #{op['status']} and cannot go to #{status} (allowed: #{allowed.empty? ? 'none' : allowed})"
    end
    raise Invalid, 'approved needs --approved-by (the human who approved)' if status == 'approved' && blank?(approved_by)
    raise Invalid, "#{status} needs --result" if %w[succeeded failed].include?(status) && blank?(result)
  end

  def locked(id)
    dir = path(id)
    File.open(File.join(dir, '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield dir
    end
  end

  def read_json(file) = JSON.parse(File.read(file))

  def write_json(file, data)
    tmp = "#{file}.tmp.#{Process.pid}"
    File.write(tmp, "#{JSON.pretty_generate(data)}\n")
    File.rename(tmp, file)
  end

  def time(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    raise Invalid, "--at must be an ISO 8601 timestamp, got #{value.inspect}"
  end

  def one_line(text) = text.to_s.gsub(/\s+/, ' ').strip

  def blank?(value) = value.nil? || value.to_s.strip.empty?
end

# Command line. Every command takes --repo; later commands take --id (an exact
# id or a unique prefix, searched only inside that repo).
class IncidentStoreCli
  USAGE = <<~TEXT
    usage: incident_store.rb <command> --repo <slug> [options]
      create --slug S --at ISO [--client C] [--severity sev2] [--repo-path DIR]
      append --id ID --at ISO --actor A --text T
      record-op --id ID --kind K --via runbook|prod_runner --at ISO [--request-id R] [--commands-file F]
      update-op --id ID --op-id OP --status S --at ISO [--approved-by W] [--result T] [--evidence P]
      set --id ID --at ISO [key=value ...] [--status S] [--probe C] [--probe-expected E]
          [--probe-result R] [--serving-version V] [--serving-source deploy_api|version_endpoint]
          [--regression NAME=pass|fail] [--fix-version V] [--pr-url U] [--merge-sha S]
      follow-up add --id ID --title T [--url U] --at ISO
      follow-up update --id ID --n K (--url U | --accepted-untracked --by W) --at ISO
      close --id ID --at ISO
      path --id ID
  TEXT
  REPEATED = %w[regression].freeze
  SET_FLAGS = { 'status' => 'status', 'probe' => 'probe', 'probe-expected' => 'probe_expected',
                'probe-result' => 'probe_result', 'serving-version' => 'serving_version',
                'serving-source' => 'serving_source', 'severity' => 'severity', 'client' => 'client',
                'release-bad' => 'release_bad', 'release-good' => 'release_good',
                'fix-version' => 'hotfix.fix_version', 'pr-url' => 'hotfix.pr_url',
                'merge-sha' => 'hotfix.merge_sha' }.freeze

  def initialize(argv, out: $stdout, err: $stderr)
    @argv = argv.dup
    @out = out
    @err = err
  end

  def run
    command = @argv.shift
    return usage(0) if %w[-h --help help].include?(command)
    return usage(2) if command.nil?

    command = "#{command} #{@argv.shift}" if command == 'follow-up'
    opts, rest = parse(@argv)
    store = IncidentStore.new(repo: opts['repo'], repo_path: opts['repo-path'])
    dispatch(command, store, opts, rest)
  rescue IncidentStore::Invalid => e
    @err.puts("incident_store: #{e.message}")
    1
  end

  private

  def dispatch(command, store, opts, rest)
    case command
    when 'create'
      emit store.create(slug: opts['slug'], at: opts['at'], client: opts['client'], severity: opts['severity'] || 'sev2')
    when 'append' then emit store.append(opts['id'], at: opts['at'], actor: opts['actor'], text: opts['text'])
    when 'record-op' then emit record_op(store, opts)
    when 'update-op' then update_op(store, opts)
    when 'set' then set(store, opts, rest)
    when 'follow-up add' then emit store.follow_up_add(opts['id'], title: opts['title'], url: opts['url'], at: opts['at'])
    when 'follow-up update' then follow_up_update(store, opts)
    when 'close' then close(store, opts)
    when 'path' then emit store.path(opts['id'])
    when 'resolve' then emit store.resolve(opts['id'])
    else usage(2)
    end
  end

  def record_op(store, opts)
    store.record_op(opts['id'], kind: opts['kind'], via: opts['via'], at: opts['at'],
                               request_id: opts['request-id'], commands_file: opts['commands-file'])
  end

  def update_op(store, opts)
    store.update_op(opts['id'], op_id: opts['op-id'], status: opts['status'], at: opts['at'],
                                approved_by: opts['approved-by'], result: opts['result'], evidence: opts['evidence'])
    emit 'ok'
  end

  def follow_up_update(store, opts)
    store.follow_up_update(opts['id'], n: opts['n'], at: opts['at'], url: opts['url'],
                                       accepted_untracked: opts.key?('accepted-untracked'), by: opts['by'])
    emit 'ok'
  end

  def close(store, opts)
    store.close(opts['id'], at: opts['at'])
    emit 'ok'
  end

  def set(store, opts, rest)
    changes = {}
    SET_FLAGS.each { |flag, key| changes[key] = opts[flag] if opts.key?(flag) }
    Array(opts['regression']).each do |row|
      name, value = row.split('=', 2)
      changes["regression.#{name}"] = value
    end
    rest.each do |pair|
      key, value = pair.split('=', 2)
      raise IncidentStore::Invalid, "expected key=value, got #{pair.inspect}" if value.nil?

      changes[key] = value
    end
    raise IncidentStore::Invalid, 'set needs at least one change' if changes.empty?

    store.set(opts['id'], changes, at: opts['at'])
    emit 'ok'
  end

  def emit(value)
    @out.puts(value.to_s.strip)
    0
  end

  def usage(code)
    (code.zero? ? @out : @err).puts(USAGE)
    code
  end

  def parse(args)
    opts = {}
    rest = []
    queue = args.dup
    until queue.empty?
      token = queue.shift
      next rest << token unless token.start_with?('--')

      name, inline = token[2..].split('=', 2)
      value = inline
      value = queue.shift if value.nil? && !queue.empty? && !queue.first.start_with?('--')
      store_option(opts, name, value)
    end
    [ opts, rest ]
  end

  def store_option(opts, name, value)
    if REPEATED.include?(name)
      (opts[name] ||= []) << value
    else
      opts[name] = value.nil? ? '' : value
    end
  end
end

exit(IncidentStoreCli.new(ARGV).run) if $PROGRAM_NAME == __FILE__
