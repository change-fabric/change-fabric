#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'optparse'
require 'time'
require_relative 'approval_console/canonical'
require_relative 'approval_console/local_store'
require_relative 'approval_console/standing_receipt'
require_relative 'change_autopilot_store'
require_relative 'change_prod_autopilot_ref'
require_relative 'cf_project_identity'

# Autopilot: a phone-approved, time-boxed receipt that lets agents on one repo,
# on one machine, skip the approval gates it lists until its signed end. It is
# a separate axis from merge modes and doctrine levels: it never reads or
# changes the merge mode, and no merge mode opens or extends it.
#
# The guards ask `ChangeAutopilot.waive!(gate, ...)` only on a would-deny path;
# a true answer means allow, and a ledger row records the waiver. The locked
# core never asks: secrets, release tags, change_override and
# CF_ALLOW_UNGATED_MERGE, force-push to trunk, and edits to LOCKED_PATHS.
#
# An autopilot covers a gate only when all of these hold (StandingReceipt plus):
#   - the receipt verifies, for this machine, against the authoritative pins;
#   - the signed repo is this project and the record's repo; the file's id is
#     the body hash;
#   - now is before autopilot_expires_at (lazy expiry: checked on every call);
#   - no <id>.ended tombstone exists;
#   - the gate is in the signed scope_list.
# Any error means not covered.
class ChangeAutopilot
  GATES = ApprovalConsole::Canonical::AUTOPILOT_GATES
  # Paths an autopilot never relaxes, even when the repo lists them as carve-outs.
  LOCKED_PATHS = %w[CHANGE.md install.rb scripts/*guard*.rb scripts/change_autopilot*.rb scripts/change_*_store.rb
                    scripts/review_gate.rb scripts/change_gate_check.rb scripts/change_policy.rb scripts/cf_host_hook.rb
                    scripts/approval_console*.rb scripts/approval_console/** approval_console/**
                    .github/workflows/release-*.yml .github/workflows/bump-tap-formula.yml .github/workflows/cf-prod.yml].freeze

  Active = Struct.new(:id, :repo, :scope_list, :expires_at, keyword_init: true)

  def self.covers?(gate, project: Dir.pwd, now: Time.now)
    new(project: project, now: now).covers?(gate)
  rescue StandardError
    false
  end

  # The autopilot id that waived `gate` (and logged it), or nil. Never raises.
  def self.waive!(gate, project: Dir.pwd, now: Time.now, **row)
    new(project: project, now: now).waive!(gate, **row)
  rescue StandardError
    nil
  end

  def self.locked_path?(path)
    LOCKED_PATHS.any? do |glob|
      glob = "#{glob}/*" if glob.end_with?('/**')
      File.fnmatch?(glob, path.to_s, File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB)
    end
  end

  attr_reader :rejected

  def initialize(project: Dir.pwd, store: ApprovalConsole::LocalStore.new, autopilots: ChangeAutopilotStore.new, now: Time.now,
                 project_id: nil, pins: :authoritative)
    @project = project
    @project_id = project_id
    @store = store
    @autopilots = autopilots
    @now = now
    @receipts = ApprovalConsole::StandingReceipt.new(project: project, store: store, now: now, pins: pins)
    @rejected = {}
  end

  def active
    @rejected = {}
    @autopilots.all.each_with_index.filter_map { |record, index| load(record, index) }
  end

  def active_for(gate) = active.find { |autopilot| autopilot.scope_list.include?(gate.to_s) }

  def covers?(gate)
    !active_for(gate).nil?
  rescue StandardError
    false
  end

  def waive!(gate, guard:, detail: nil, command: nil, session: nil)
    autopilot = active_for(gate) or return nil
    @autopilots.append_ledger(autopilot.id, { 'at' => @now.utc.iso8601, 'gate' => gate.to_s, 'guard' => guard.to_s,
                                              'command_sha256' => command && Digest::SHA256.hexdigest(command.to_s),
                                              'detail' => detail, 'session' => session })
    autopilot.id
  rescue StandardError
    nil
  end

  # Tombstones every active autopilot for this repo; returns their ids.
  def end!(by:, reason:)
    active.map do |autopilot|
      @autopilots.end!(autopilot_id: autopilot.id, by: by, reason: reason, at: @now)
      autopilot.id
    end
  end

  def ledger(autopilot_id) = @autopilots.ledger(autopilot_id)

  private

  def project_id = @project_id ||= CfProjectIdentity.for(@project).id

  def load(record, index)
    body = ApprovalConsole::StandingReceipt.body_of(record, 'autopilot')
    id = body ? ApprovalConsole::Canonical.body_sha256(record['proof']['body']) : "record-#{index}"
    reason = body ? problem(record, body, id) : 'malformed'
    return Active.new(id: id, repo: body['repo'], scope_list: body['scope_list'], expires_at: Time.iso8601(body['autopilot_expires_at'])) unless reason

    @rejected[id] = reason
    nil
  end

  def problem(record, body, id)
    return 'wrong-project' unless body['repo'] == project_id && record['repo'] == body['repo']
    return 'tampered' unless record['autopilot_id'] == id
    return 'ended' if @autopilots.ended?(id)
    return 'unverified' if @receipts.verification_problem(record['proof'])

    @receipts.time_problem(record['proof'], body, 'autopilot_expires_at')
  end
end

# CLI. `status [--json]`, `end [--reason TEXT]`, `ledger [ID]`. There is no
# verb that opens or extends an autopilot: that is a new phone request.
class ChangeAutopilotCLI
  USAGE = 'usage: change_autopilot.rb status [--json] | end [--reason TEXT] | ledger [ID]'

  def self.run(argv, out: $stdout, err: $stderr, autopilot: nil, by: ENV['USER'] || 'agent', root: nil, ender: ChangeProdAutopilotRef.method(:publish_end))
    verb, *rest = argv
    opts = {}
    OptionParser.new do |o|
      o.on('--json') { opts[:json] = true }
      o.on('--reason TEXT') { |value| opts[:reason] = value }
    end.parse!(rest)
    autopilot ||= ChangeAutopilot.new
    case verb
    when 'status' then status(autopilot, out, opts[:json])
    when 'end' then finish(autopilot, out, err, by, opts[:reason] || 'ended early', root || CfProjectIdentity.for(Dir.pwd).root, ender)
    when 'ledger' then ledger(autopilot, out, rest.first)
    else
      err.puts USAGE
      2
    end
  rescue OptionParser::ParseError
    err.puts USAGE
    2
  end

  def self.status(autopilot, out, json)
    active = autopilot.active
    rows = active.map { |a| { 'id' => a.id, 'gates' => a.scope_list, 'ends_at' => a.expires_at.utc.iso8601 } }
    if json
      out.puts JSON.generate('autopilot' => rows, 'rejected' => autopilot.rejected)
    elsif rows.empty?
      out.puts 'no autopilot is active for this repo'
    else
      rows.each { |row| out.puts "autopilot #{row['id'][0, 12]}: #{row['gates'].join(', ')} until #{row['ends_at']}" }
    end
    0
  end

  # The local tombstone is the source of truth for the gates. The prod runner
  # reads its own end marker, so a failure to write it is loud and exits 1.
  def self.finish(autopilot, out, err, by, reason, root, ender)
    ids = autopilot.end!(by: by, reason: reason)
    out.puts(ids.empty? ? 'no autopilot was active' : "ended autopilot #{ids.map { |id| id[0, 12] }.join(', ')}")
    ids.map { |id| ender.call(root: root, id: id, by: by, reason: reason) }.reduce(0) do |status, outcome|
      (outcome.ok? ? out : err).puts("change_autopilot: #{outcome.note}") if outcome.note
      outcome.ok? ? status : 1
    end
  rescue StandardError => e
    err.puts "change_autopilot: end failed: #{e.message}"
    1
  end

  def self.ledger(autopilot, out, id)
    ids = id ? [ id ] : autopilot.active.map(&:id)
    ids.each { |each| autopilot.ledger(each).each { |row| out.puts JSON.generate(row.merge('autopilot' => each)) } }
    0
  end
end

exit(ChangeAutopilotCLI.run(ARGV)) if __FILE__ == $PROGRAM_NAME
