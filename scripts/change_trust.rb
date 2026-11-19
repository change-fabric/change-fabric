#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require_relative 'change_apps'
require_relative 'change_frontmatter'
require_relative 'change_approval_store'
require_relative 'change_override_store'
require_relative 'change_policy'
require_relative 'cf_project_identity'
require_relative 'approval_console/proof_check'
require_relative 'emit_digest'
require_relative 'change_trust_files'

# Base-branch trust for the steps cf:change executes on the host: boot.up,
# boot.down and (from 0.17.0) each command lane entry. A gate that runs
# whatever the pull request says is no gate: a branch could replace a check
# with `true`, or run anything on the maintainer's machine. So the definitions
# on the base branch are authoritative. A step whose definition at HEAD equals
# the base branch's runs; one that differs (or is new) runs only once a human
# has approved that exact definition for that exact commit with
# change_approve.rb, which refuses without a real terminal. There is no author
# exemption: the maintainer's own pull requests need the same approval.
#
# A definition is reduced to a digest over the fields that change what
# executes, so a reordered CHANGE.md is not a change and a one-character edit
# to a `run` string is. A command entry's digest also covers the content of
# the repo files it runs (ChangeTrustFiles), so editing a script the lane
# calls is a change too. An entry whose files cannot be verified (a path out
# of the repo, a set over the cap) gets an `unverified-` digest that never
# matches the base branch: it runs only once approved.
module ChangeTrust
  APPROVE_COMMAND = 'ruby ~/.claude/cf/bin/change_approve.rb'

  # Where the base branch lives. `note` explains a degraded resolution (a
  # failed fetch, no ref at all); `sha` nil means nothing resolved and every
  # step is untrusted.
  Base = Struct.new(:ref, :sha, :note, keyword_init: true)

  # The outcome of comparing HEAD's step definitions against the base branch.
  # `sources` maps each trusted step to :base or :approved; `untrusted` lists
  # the rest.
  Verdict = Struct.new(:sources, :untrusted, :head_digests, :base_digests, :base_ref, :base_sha, :head_sha,
                       :note, :reasons, :policy_sha, keyword_init: true) do
    def trusted?(step) = sources.key?(step)

    def refusal(step)
      base_digest = base_digests[step]
      against = base_digest ? "base: #{base_digest}" : 'new step'
      reason = reasons&.dig(step)
      "refusing to run #{step}: its definition differs from #{base_ref || 'the base branch'}\n  " \
        "head digest #{head_digests[step]} (#{against})\n  " \
        "#{reason ? "#{reason}\n  " : ''}" \
        "A human must approve it for this commit from their own terminal:\n    " \
        "#{APPROVE_COMMAND} #{head_sha}"
    end

    # The gate record's `manifest.trust` block, listing only the steps that
    # actually executed.
    def manifest(executed)
      steps = executed.select { |step| trusted?(step) }.to_h do |step|
        [ step, { 'digest' => head_digests[step], 'source' => sources[step].to_s } ]
      end
      { 'base_ref' => base_ref.to_s, 'base_sha' => base_sha.to_s, 'steps' => steps }
    end
  end

  module_function

  # Plain hex since EmitDigest unified the format. Records written before it
  # carry a `sha256:` prefix; `normalize` strips it wherever one is read.
  UNVERIFIED = 'unverified-'

  def digest(fields)
    hex = EmitDigest.of(fields)
    fields.is_a?(Hash) && fields['files_error'] ? "#{UNVERIFIED}#{hex}" : hex
  end

  # Whether the base branch's digest vouches for HEAD's. An unverified digest
  # is never vouched for, even when the base carries the same one.
  def base_match?(base_digest, head_digest)
    !base_digest.nil? && base_digest == head_digest && !head_digest.to_s.start_with?(UNVERIFIED)
  end

  def normalize(digest) = digest.to_s.delete_prefix('sha256:')

  # { step name => the fields that define it } for one loaded config. `prefix`
  # names the app in a monorepo ("portal/boot.up"); it is empty otherwise.
  # `files` is where command entries' covered files are read: the working
  # tree of the config's repo by default, a commit for a snapshot.
  def step_definitions(config, prefix: '', files: nil)
    boot = config.boot
    defs = {}
    defs["#{prefix}boot.up"] = boot_fields(boot, boot.up) if boot.up?
    defs["#{prefix}boot.down"] = boot_fields(boot, boot.down) unless boot.down.empty?
    entries = command_entries(config)
    return defs if entries.empty?

    source = files || ChangeTrustFiles::Source.working_tree(git_root(config.repo_root))
    cwd = relative_dir(config.repo_root, source.root)
    entries.each do |entry|
      coverage = ChangeTrustFiles.cover(entry, source, cwd: cwd)
      defs["#{prefix}command:#{entry['name']}"] = command_fields(entry, boot.env_file_entries, coverage)
    end
    defs
  end

  def git_root(dir)
    out, status = Open3.capture2e('git', '-C', dir, 'rev-parse', '--show-toplevel')
    status.success? && !out.strip.empty? ? out.strip : dir
  end

  # `dir` relative to `root`, '' when they are the same. A snapshot's app
  # dir may not exist on disk, so a path that cannot be resolved is compared
  # as written.
  def relative_dir(dir, root)
    real = ->(path) { File.exist?(path) ? File.realpath(path) : File.expand_path(path) }
    rel = Pathname.new(real.call(dir)).relative_path_from(Pathname.new(real.call(root))).to_s
    rel == '.' ? '' : rel
  end

  # The command lane entries that would execute under this config's profile:
  # an entry with a `profiles:` list it is not in is skipped, so it is not a
  # step that ran.
  def command_entries(config)
    return [] unless config.enabled_lanes.include?('command')

    Array(config.lane('command')['commands']).select do |entry|
      entry.is_a?(Hash) && (entry['profiles'].nil? || Array(entry['profiles']).include?(config.profile))
    end
  end

  # `env_file` is boot.env_file: the command lane resolves declared names from
  # it, so pointing it at another file changes what an entry runs against.
  # `coverage` is ChangeTrustFiles.cover's result: the content digest of
  # every repo file the entry runs, or why they could not be verified.
  def command_fields(entry, env_file, coverage = { 'files' => {}, 'error' => nil })
    fields = {
      'name' => entry['name'].to_s, 'run' => entry['run'].to_s, 'env' => Array(entry['env']).map(&:to_s).sort,
      'env_file' => env_file,
      'timeout_seconds' => entry['timeout_seconds'], 'artifacts' => Array(entry['artifacts']).map(&:to_s),
      'profiles' => entry['profiles'] && Array(entry['profiles']).map(&:to_s).sort, 'retries' => entry.fetch('retries', 0),
      'trust_paths' => Array(entry['trust_paths']).map(&:to_s), 'files' => coverage['files']
    }
    coverage['error'] ? fields.merge('files_error' => coverage['error']) : fields
  end

  def boot_fields(boot, run)
    {
      'run' => run, 'env' => boot.env_names.sort, 'env_file' => boot.env_file_entries,
      'timeout_seconds' => boot.timeout_seconds
    }
  end

  def digests(definitions) = definitions.to_h.transform_values { |fields| digest(fields) }

  def step_digests(config, prefix: '') = digests(step_definitions(config, prefix: prefix))

  # Step definitions as committed at `ref`, read with `git show` (never from
  # the working tree, never by checking anything out). In a monorepo every
  # enabled app's config file is read at the same ref. A ref with no
  # CHANGE.md, or one that no longer parses, yields {}: nothing on it can
  # vouch for anything at HEAD.
  #
  # A config that exists but cannot be loaded returns nil, never {}: "could
  # not read the steps" must not read as "there are no steps". `apps` limits a
  # monorepo snapshot to the named apps, so an app that does not define the
  # requested profile cannot sink the snapshot of one that does.
  def snapshot_definitions(root, ref, profile: nil, apps: nil)
    with_snapshot(root, ref) do |registry|
      return {} unless registry

      # An app named explicitly counts even when disabled: `--app NAME` runs a
      # disabled app, so its steps need the same comparison and approval.
      entries = if apps && registry.multi_app?
                  registry.entries.select { |entry| apps.include?(entry.name) }
      else
                  registry.enabled_entries
      end
      entries.each_with_object({}) do |entry, defs|
        prefix = registry.multi_app? ? "#{entry.name}/" : ''
        files = ChangeTrustFiles::Source.at_ref(root, ref, entry.root)
        defs.merge!(step_definitions(entry.load(profile: profile), prefix: prefix, files: files))
      end
    end
  rescue StandardError
    nil
  end

  # { app name (nil in single-app mode) => profile names it defines, or
  # [nil] when it defines none }, as committed at `ref`. change_approve.rb
  # walks this so every definition a run could execute can be approved,
  # including a disabled app's (`--app NAME` runs one).
  def profiles_by_app(root, ref)
    with_snapshot(root, ref) do |registry|
      return {} unless registry

      registry.entries.to_h do |entry|
        profiles = entry_profiles(entry)
        [ registry.multi_app? ? entry.name : nil, profiles.empty? ? [ nil ] : profiles ]
      end
    end
  end

  # Yields the app registry as committed at `ref`, every app config written
  # beside its CHANGE.md in a temp dir, or nil when `ref` has no CHANGE.md.
  def with_snapshot(root, ref)
    Dir.mktmpdir('cf-trust') do |dir|
      change_md = File.join(dir, 'CHANGE.md')
      next yield(nil) unless write_blob(root, ref, 'CHANGE.md', change_md)

      app_paths(change_md).each { |rel| write_blob(root, ref, rel, File.join(dir, rel)) }
      yield ChangeAppRegistry.load(change_md)
    end
  end

  def entry_profiles(entry)
    raw = entry.synthetic ? ChangeFrontmatter.parse_file(entry.config_path) : YAML.safe_load_file(entry.config_path, aliases: true)
    front = raw.is_a?(Hash) ? raw['change_config'] : nil
    profiles = front.is_a?(Hash) ? front['profiles'] : nil
    profiles.is_a?(Hash) ? profiles.keys.map(&:to_s) : []
  end

  def app_paths(change_md)
    apps = ChangeFrontmatter.parse_file(change_md).dig('change_config', 'apps')
    return [] unless apps.is_a?(Hash)

    apps.values.filter_map { |entry| entry.is_a?(Hash) ? entry['config'].to_s : nil }
        .reject { |rel| rel.empty? || rel.start_with?('/') || rel.split('/').include?('..') }
  end

  def write_blob(root, ref, rel, dest)
    out, status = Open3.capture2e('git', '-C', root, 'show', "#{ref}:#{rel}")
    return false unless status.success?

    FileUtils.mkdir_p(File.dirname(dest))
    File.write(dest, out)
    true
  end

  # The base branch: the repo's default branch (origin/HEAD, else main), or
  # the change_policy.gate.trunk named by that default branch's own CHANGE.md.
  # The trunk is read from the base, never from the working tree, so a pull
  # request cannot point the comparison at a branch of its own.
  def resolve_base(root, fetch: true)
    notes = []
    default = default_branch(root)
    notes << fetch_note(root, default) if fetch
    trunk = trunk_at(root, "origin/#{default}") || default
    notes << fetch_note(root, trunk) if fetch && trunk != default
    ref = "origin/#{trunk}"
    sha = rev_parse(root, "#{ref}^{commit}")
    notes << "no base ref resolves (#{ref}); every step is untrusted" unless sha
    Base.new(ref: ref, sha: sha, note: notes.compact.join('; ').then { |text| text.empty? ? nil : text })
  end

  def default_branch(root)
    out, status = Open3.capture2e('git', '-C', root, 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
    status.success? && !out.strip.empty? ? out.strip.delete_prefix('origin/') : 'main'
  end

  def trunk_at(root, ref)
    out, status = Open3.capture2e('git', '-C', root, 'show', "#{ref}:CHANGE.md")
    return nil unless status.success?

    trunk = ChangeFrontmatter.parse(out).dig('change_policy', 'gate', 'trunk')
    trunk.is_a?(String) && !trunk.strip.empty? ? trunk.strip : nil
  end

  def fetch_note(root, branch)
    _out, status = Open3.capture2e('git', '-C', root, 'fetch', '--quiet', 'origin', branch)
    status.success? ? nil : "could not fetch origin/#{branch}; using the last fetched ref"
  end

  def rev_parse(root, ref)
    out, status = Open3.capture2e('git', '-C', root, 'rev-parse', '--verify', '--quiet', ref)
    status.success? && !out.strip.empty? ? out.strip : nil
  end

  # A step is trusted when its HEAD digest equals the base digest of the same
  # name, or when an approval for (this sha, that step, that digest) exists.
  # A step absent on the base is untrusted until approved.
  def verify(head_digests:, base_digests:, approvals:, head_sha: nil, base: nil, reasons: {})
    sources = {}
    untrusted = []
    head_digests.each do |step, step_digest|
      if base_match?(base_digests[step], step_digest)
        sources[step] = :base
      elsif approvals.include?([ step, step_digest ])
        sources[step] = :approved
      else
        untrusted << step
      end
    end
    Verdict.new(sources: sources, untrusted: untrusted, head_digests: head_digests, base_digests: base_digests,
                base_ref: base&.ref, base_sha: base&.sha, head_sha: head_sha, note: base&.note,
                reasons: reasons)
  end

  # The run-time entry point: resolve and fetch the base, read its
  # definitions, and compare HEAD's (as loaded from the working tree) against
  # them and against this sha's approvals.
  # `apps` names the app being run in a monorepo, so the base snapshot reads
  # only that app's config under this profile.
  # `base` overrides the resolved base: a schedule compares against the
  # default-branch snapshot it already loaded, not the per-PR gate trunk.
  #
  # Before any approval counts, every approval and override proof for this
  # sha is verified (0.26.0) under the default branch's policy
  # (ChangePolicy.authoritative; `authority` injects one). When a step
  # approval proof does not stand, or the policy cannot be read, no approval
  # counts: only steps equal to the base run. The policy commit is returned
  # as `policy_sha` and named in the note.
  def evaluate(root:, head_sha:, head_definitions:, profile: nil, apps: nil, fetch: true, base: nil, authority: nil,
               proof_store: nil)
    base ||= resolve_base(root, fetch: fetch)
    base_defs = base_definitions(root, base, profile, apps)
    records = proof_records(head_sha, profile)
    # Read only when there is a record to judge, so a run without approvals
    # makes no extra fetch or GitHub call.
    authority ||= approval_authority(root, base, fetch) if records
    problems = records ? proof_problems(root, head_sha, records, authority, proof_store) : {}
    approvals = problems[:approvals] ? [] : ChangeApprovalStore.new(head_sha).approvals
    verdict = verify(head_digests: digests(head_definitions), base_digests: digests(base_defs),
                     approvals: approvals, head_sha: head_sha, base: base,
                     reasons: file_reasons(head_definitions, base_defs))
    verdict.policy_sha = authority.is_a?(ChangePolicy::Authority) ? authority.policy_sha : nil
    verdict.note = [ verdict.note, *problems.values.compact ].compact.join('; ').then { |text| text.empty? ? nil : text }
    verdict
  end

  # The default branch's approval policy for a run, or the reason it cannot
  # be read (a String). Without a fetch (tests, a snapshot caller) the already
  # resolved base commit is read in place.
  def approval_authority(root, base, fetch)
    if fetch
      ChangePolicy.authoritative(root: root, repo: ChangePolicy.origin_repo(root).to_s)
    elsif base.sha
      ChangePolicy::Authority.new(policy: ChangePolicy.for_ref(root, base.sha), policy_sha: base.sha, ref: base.ref)
    else
      'no default branch resolves'
    end
  rescue ChangePolicy::Unreadable => e
    e.message
  end

  # The approval and override records a run judges for one sha and profile.
  ProofRecords = Struct.new(:entries, :override, :profile, keyword_init: true)

  # This sha's ProofRecords, or nil when there is neither kind of record.
  def proof_records(head_sha, profile)
    entries = ChangeApprovalStore.new(head_sha).entries
    override = ChangeOverrideStore.new(head_sha, profile: profile).read
    entries.empty? && override.nil? ? nil : ProofRecords.new(entries: entries, override: override, profile: profile)
  end

  # { approvals: why no step approval counts, override: why the override
  # does not stand }, each nil when fine. Fails closed on an unreadable policy.
  def proof_problems(root, head_sha, records, authority, proof_store)
    entries, override, profile = records.to_a
    return { approvals: "approval policy unreadable (#{authority}); no approval counts" } unless authority.is_a?(ChangePolicy::Authority)

    policy = authority.policy
    return {} unless policy

    check = ApprovalConsole::ProofCheck.new(level: policy.require_approval_proof, pins: policy.approval_pins,
                                            **{ store: proof_store }.compact)
    repo = CfProjectIdentity.for(root).id
    approvals = entries.empty? ? nil : check.approvals_problem(entries, repo: repo, sha: head_sha)
    { approvals: approvals && "#{approvals}; no approval counts (policy #{authority.policy_sha.to_s[0, 12]})",
      override: override && override_problem(check, override, repo, head_sha, profile) }
  end

  def override_problem(check, record, repo, sha, profile)
    return 'override record is malformed' unless record.is_a?(Hash)

    check.override_problem(record, repo: repo, sha: sha, profile: profile)
  end

  # { step => why its covered files make it a change }, for the refusal.
  def file_reasons(head_definitions, base_definitions)
    head_definitions.to_h.each_with_object({}) do |(step, fields), reasons|
      next unless fields.is_a?(Hash) && fields.key?('files')

      if fields['files_error']
        reasons[step] = "covered files cannot be verified: #{fields['files_error']}"
      elsif (base = base_definitions[step])
        changed = ChangeTrustFiles.changed(fields['files'], base['files'])
        reasons[step] = "covered files changed: #{changed.join(', ')}" unless changed.empty?
      end
    end
  end

  # The base branch's digests, or {} when the base cannot be resolved or read:
  # every step is then untrusted until approved, never trusted by default.
  def base_digests(root, base, profile, apps) = digests(base_definitions(root, base, profile, apps))

  def base_definitions(root, base, profile, apps)
    return {} unless base.sha

    snapshot_definitions(root, base.sha, profile: profile, apps: apps) || {}
  end

  # The merge and tag guards' question: does this gate record's trust block
  # prove that every step defined at `sha` ran as the base branch or an
  # approval defines it? nil when it does, else the reason it does not.
  # `apps` scopes a monorepo check to the apps the rule gates. A config at
  # `sha` that cannot be loaded is a problem, not an absence of steps.
  def record_problem(root:, sha:, record:, profile: nil, apps: nil)
    definitions = snapshot_definitions(root, sha, profile: profile, apps: apps)
    return "the step definitions committed at #{sha[0, 12]} could not be loaded; fix CHANGE.md and re-run change_run.rb all" unless definitions

    head = digests(definitions)
    return nil if head.empty?

    recorded = recorded_steps(record)
    return "the gate record for #{sha[0, 12]} predates step trust; re-run change_run.rb all" unless recorded

    base = resolve_base(root, fetch: false)
    base_digests = base_digests(root, base, profile, apps)
    approvals = ChangeApprovalStore.new(sha).approvals
    head.each do |step, step_digest|
      unless normalize(recorded.dig(step, 'digest')) == step_digest
        return "#{step} at #{sha[0, 12]} is not the definition the recorded run executed; re-run change_run.rb all"
      end
      next if base_match?(base_digests[step], step_digest) || approvals.include?([ step, step_digest ])

      return "#{step} at #{sha[0, 12]} differs from #{base.ref} and has no approval; " \
             "a human must run #{APPROVE_COMMAND} #{sha}"
    end
    nil
  end

  # Every trust step a gate record carries, top-level and per app, or nil when
  # the record has no trust block anywhere (written before 0.17.0).
  def recorded_steps(record)
    return nil unless record.is_a?(Hash)

    blocks = [ record.dig('manifest', 'trust') ]
    (record['apps'] || {}).each_value { |entry| blocks << entry.dig('manifest', 'trust') if entry.is_a?(Hash) }
    blocks.compact!
    return nil if blocks.empty?

    blocks.each_with_object({}) { |block, steps| steps.merge!(block['steps'] || {}) }
  end
end
