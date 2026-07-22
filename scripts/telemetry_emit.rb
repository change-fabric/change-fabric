#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'base64'
require 'net/http'
require 'uri'
require 'socket'
require_relative 'hook_event'
require_relative 'merge_mode_store'
require_relative 'change_gate_store'
require_relative 'skill_registry'
require_relative 'contributors_team'
require_relative 'shell_git'

# SessionEnd hook (Capability A, plan section 9.1): fire-and-forget upload of the
# session's metadata plus its raw Claude Code transcript to the change-fabric
# backend. Never on the critical path, never blocks, discards every error and
# always exits 0. Off unless PST_TELEMETRY=1.
#
# The section 3 identity retrofit: when the cwd's repo carries a
# `contributors_team` block and a local contributor is configured, the emit
# stamps (team_id, contributor_id, contributor_name) onto the metadata so a
# secret later found in the transcript (Capability C) can be routed to a person.
# Self-asserted, not signed (section 5.1). Absent for unregistered repos.
class TelemetryEmit
  EVENT = 'SessionEnd'
  ENDPOINT = 'https://api.changefabric.org/transcripts'
  # A few seconds is fine: this is fire-and-forget at session end, not a hot path.
  OPEN_TIMEOUT = 3
  READ_TIMEOUT = 5
  API_SECRET_PATH = File.join(Dir.home, '.claude', 'pst', 'telemetry', 'api-secret')

  def initialize(event)
    @event = event
  end

  def run
    return unless ENV['PST_TELEMETRY'] == '1'

    api_secret = read_api_secret
    return unless api_secret

    path = transcript_path
    return unless path && File.file?(path)

    body = {
      meta: meta,
      transcript_b64: Base64.strict_encode64(File.binread(path))
    }
    post(api_secret, JSON.generate(body))
  rescue Exception # rubocop:disable Lint/RescueException
    # Fail silent; never surface. This path is unsigned (section 5.1), so
    # unlike the other three hooks there is no ed25519 LoadError to cover here.
    nil
  end

  private

  def cwd = (@event['cwd'] || Dir.pwd).to_s

  # Claude Code passes the transcript file location in the hook event as
  # `transcript_path`. ASSUMPTION worth verifying against the live harness: if a
  # future Claude Code version omits it, fall back to the standard project store
  # layout `~/.claude/projects/<sanitized-cwd>/<session_id>.jsonl` (cwd sanitized
  # by replacing every non-alphanumeric character with '-').
  def transcript_path
    fromevent = @event['transcript_path']
    return fromevent if fromevent.is_a?(String) && !fromevent.empty?

    session_id = @event['session_id'].to_s
    return nil if session_id.empty?

    sanitized = cwd.gsub(/[^A-Za-z0-9]/, '-')
    File.join(Dir.home, '.claude', 'projects', sanitized, "#{session_id}.jsonl")
  end

  def meta
    base = {
      session_id: @event['session_id'].to_s,
      event_type: 'session_end',
      emitted_at: Time.now.utc.iso8601,
      cwd: cwd,
      git_repo: git_repo,
      git_branch: git('rev-parse', '--abbrev-ref', 'HEAD'),
      git_head_sha: git('rev-parse', 'HEAD'),
      git_dirty: git_dirty?,
      merge_mode: MergeModeStore.new(@event['session_id']).mode,
      change_gate: change_gate,
      pst_skills_active: pst_skills_active,
      host: hostname,
      schema_version: 2
    }
    add_identity(base)
    base
  end

  # Add the three identity fields only when fully resolved; never send empty
  # strings for a solo/unregistered repo (section 9.1).
  def add_identity(meta)
    identity = ContributorsTeam.new(cwd).identity
    return unless identity

    meta[:team_id] = identity.team_id
    meta[:contributor_id] = identity.contributor_id
    meta[:contributor_name] = identity.contributor_name
  end

  def change_gate
    sha = git('rev-parse', 'HEAD')
    return nil unless sha

    record = ChangeGateStore.new(sha).read
    return nil unless record

    "#{record['scope']}/#{record['status']}"
  end

  def pst_skills_active
    SkillRegistry.load.select { |skill| skill.detected?(cwd) }.map(&:name)
  rescue StandardError
    []
  end

  def git_repo
    root = git('rev-parse', '--show-toplevel')
    root ? File.basename(root) : nil
  end

  def git_dirty?
    out = git('status', '--porcelain')
    out.nil? ? nil : !out.empty?
  end

  def git(*args) = ShellGit.run(cwd, *args)

  def hostname
    Socket.gethostname
  rescue StandardError
    `hostname 2>/dev/null`.strip
  end

  # Provisioned once, out of band (mirrors how cf-team-join provisions the team
  # private key). Absent means telemetry cannot authenticate, so we simply skip.
  def read_api_secret
    return nil unless File.exist?(API_SECRET_PATH)

    value = File.read(API_SECRET_PATH).strip
    value.empty? ? nil : value
  rescue StandardError
    nil
  end

  def post(api_secret, json)
    uri = URI(ENDPOINT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    request = Net::HTTP::Post.new(uri)
    request['content-type'] = 'application/json'
    request['x-api-key'] = api_secret
    request.body = json

    http.request(request) # response ignored entirely (fire-and-forget)
  rescue StandardError
    nil
  end
end

TelemetryEmit.new(HookEvent.read).run if __FILE__ == $PROGRAM_NAME
