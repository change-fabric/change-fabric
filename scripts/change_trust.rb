#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative 'change_apps'
require_relative 'change_frontmatter'
require_relative 'change_approval_store'

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
# to a `run` string is.
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
                       :note, keyword_init: true) do
    def trusted?(step) = sources.key?(step)

    def refusal(step)
      base_digest = base_digests[step]
      against = base_digest ? "base: #{base_digest}" : 'new step'
      "refusing to run #{step}: its definition differs from #{base_ref || 'the base branch'}\n  " \
        "head digest #{head_digests[step]} (#{against})\n  " \
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

  def digest(fields) = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(fields)))}"

  def canonical(value)
    case value
    when Hash then value.to_h { |key, item| [ key.to_s, canonical(item) ] }.sort.to_h
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end

  # { step name => the fields that define it } for one loaded config. `prefix`
  # names the app in a monorepo ("portal/boot.up"); it is empty otherwise.
  def step_definitions(config, prefix: '')
    boot = config.boot
    defs = {}
    defs["#{prefix}boot.up"] = boot_fields(boot, boot.up) if boot.up?
    defs["#{prefix}boot.down"] = boot_fields(boot, boot.down) unless boot.down.empty?
    defs
  end

  def boot_fields(boot, run)
    {
      'run' => run, 'env' => boot.env_names.sort, 'env_file' => boot.env_file_entries,
      'timeout_seconds' => boot.timeout_seconds
    }
  end

  def digests(definitions) = definitions.transform_values { |fields| digest(fields) }

  def step_digests(config, prefix: '') = digests(step_definitions(config, prefix: prefix))

  # Step definitions as committed at `ref`, read with `git show` (never from
  # the working tree, never by checking anything out). In a monorepo every
  # enabled app's config file is read at the same ref. A ref with no
  # CHANGE.md, or one that no longer parses, yields {}: nothing on it can
  # vouch for anything at HEAD.
  def snapshot_definitions(root, ref, profile: nil)
    Dir.mktmpdir('cf-trust') do |dir|
      change_md = File.join(dir, 'CHANGE.md')
      return {} unless write_blob(root, ref, 'CHANGE.md', change_md)

      app_paths(change_md).each { |rel| write_blob(root, ref, rel, File.join(dir, rel)) }
      registry = ChangeAppRegistry.load(change_md)
      registry.enabled_entries.each_with_object({}) do |entry, defs|
        prefix = registry.multi_app? ? "#{entry.name}/" : ''
        defs.merge!(step_definitions(entry.load(profile: profile), prefix: prefix))
      end
    end
  rescue StandardError
    {}
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
  def verify(head_digests:, base_digests:, approvals:, head_sha: nil, base: nil)
    sources = {}
    untrusted = []
    head_digests.each do |step, step_digest|
      if base_digests[step] == step_digest
        sources[step] = :base
      elsif approvals.include?([ step, step_digest ])
        sources[step] = :approved
      else
        untrusted << step
      end
    end
    Verdict.new(sources: sources, untrusted: untrusted, head_digests: head_digests, base_digests: base_digests,
                base_ref: base&.ref, base_sha: base&.sha, head_sha: head_sha, note: base&.note)
  end

  # The run-time entry point: resolve and fetch the base, read its
  # definitions, and compare HEAD's (as loaded from the working tree) against
  # them and against this sha's approvals.
  def evaluate(root:, head_sha:, head_definitions:, profile: nil, fetch: true)
    base = resolve_base(root, fetch: fetch)
    base_digests = base.sha ? digests(snapshot_definitions(root, base.sha, profile: profile)) : {}
    verify(head_digests: digests(head_definitions), base_digests: base_digests,
           approvals: ChangeApprovalStore.new(head_sha).approvals, head_sha: head_sha, base: base)
  end

  # The merge and tag guards' question: does this gate record's trust block
  # prove that every step defined at `sha` ran as the base branch or an
  # approval defines it? nil when it does, else the reason it does not.
  # `apps` scopes a monorepo check to the apps the rule gates.
  def record_problem(root:, sha:, record:, profile: nil, apps: nil)
    head = digests(snapshot_definitions(root, sha, profile: profile))
    head = head.select { |step, _| apps.include?(step.split('/').first) } if apps
    return nil if head.empty?

    recorded = recorded_steps(record)
    return "the gate record for #{sha[0, 12]} predates step trust; re-run change_run.rb all" unless recorded

    base = resolve_base(root, fetch: false)
    base_digests = base.sha ? digests(snapshot_definitions(root, base.sha, profile: profile)) : {}
    approvals = ChangeApprovalStore.new(sha).approvals
    head.each do |step, step_digest|
      unless recorded.dig(step, 'digest') == step_digest
        return "#{step} at #{sha[0, 12]} is not the definition the recorded run executed; re-run change_run.rb all"
      end
      next if base_digests[step] == step_digest || approvals.include?([ step, step_digest ])

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
