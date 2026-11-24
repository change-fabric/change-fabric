#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'tmpdir'
require 'time'
require_relative 'approval_console/canonical'
require_relative 'approval_console/client'
require_relative 'approval_console/local_store'
require_relative 'approval_console/proof_check'
require_relative 'approval_console/recorder'
require_relative 'change_autopilot'
require_relative 'change_policy'
require_relative 'change_run_script_store'
require_relative 'cf_project_identity'

# The only way a queued script runs. It runs one script from
# ~/.claude/cf/manual/queue/ if, and only if, Patrick's phone approved that
# exact script text at the commit this checkout is on:
#
#   1. the script's bytes hash to a ChangeRunScriptStore record for this repo
#      and HEAD, whose passkey receipt verifies against the `approval_pins` of
#      the default branch's CHANGE.md and signs the same hash, path, text,
#      account and commit;
#   2. the receipt is under 15 minutes old (it is also single-use);
#   3. when the receipt names an AWS account, the current account is it, asked
#      of --profile, else the receipt's own profile, else AWS_PROFILE;
#   4. the receipt is marked consumed in a local ledger and then on the console,
#      before anything runs, so a reuse is refused whether or not the script
#      succeeds. A console that cannot be reached refuses the run (the ledger
#      mark is released, so a retry is possible once it is back);
#   5. the script runs with no tty and its output streams through; on success it
#      moves to queue/done/.
#
# With no recorded approval for the script, an active autopilot for this repo
# that lists `run_script` stands in (no receipt, so rules 1 to 4 do not apply).
# The run is logged to the autopilot's ledger and to the run-ledger under the
# autopilot id in place of a request id, and the script gets only the one AWS
# profile it was given (--profile or AWS_PROFILE).
#
# Execution is local only. The hooks deny every other way to run a queued
# script (prod_approval_guard.rb); this is the one permitted route. Break-glass:
# approval_console/infra/redeploy.sh and the other manual scripts need no
# console or receipt, so a human can still run them from a real terminal when
# the console is down.
class CfRunApproved
  MAX_AGE = ApprovalConsole::Canonical::RUN_SCRIPT_LIFETIME
  Refused = Class.new(StandardError)

  def initialize(home: Dir.home, store: nil, client: nil, authority: nil, clock: -> { Time.now }, account: nil,
                 profile: nil, env: ENV, out: $stdout, err: $stderr, runner: nil, autopilot: nil)
    @home = home
    @store = store
    @client = client
    @authority = authority
    @clock = clock
    @account = account
    @profile = profile
    @env = env
    @out = out
    @err = err
    @runner = runner || method(:spawn_script)
    @autopilot = autopilot || method(:autopilot_waiver)
  end

  # Exit status: 0 ran and succeeded, 1 refused, else the script's own status.
  def run(script, repo: Dir.pwd)
    path = File.expand_path(script)
    text = read_script(path)
    root = git_root(repo)
    sha = git_head(root)
    record = recorded(root, sha, text)
    request = record ? approved_request(record['proof'], root, sha, path, text) : autopilot_request(root, sha, path, text)
    status = run_snapshot(path, text, root, sha, request)
    finish(path, text, status)
  rescue Refused => e
    @err.puts "[cf_run_approved] refused: #{e.message}"
    1
  end

  private

  def queue_dir = File.join(@home, '.claude', 'cf', 'manual', 'queue')
  def ledger_dir = File.join(@home, '.claude', 'cf', 'change', 'run-ledger')

  def read_script(path)
    raise Refused, "#{path} is not a file" unless File.file?(path)
    raise Refused, "#{path} is not directly in #{queue_dir}" unless File.dirname(File.realpath(path)) == File.realpath(queue_dir)

    text = File.binread(path).force_encoding(Encoding::UTF_8)
    raise Refused, 'the script is not valid UTF-8 text' unless text.valid_encoding?

    text
  rescue Errno::ENOENT
    raise Refused, "#{queue_dir} does not exist"
  end

  def git_root(repo)
    out, status = Open3.capture2e('git', '-C', repo, 'rev-parse', '--show-toplevel')
    raise Refused, "#{repo} is not a git checkout" unless status.success?

    out.strip
  end

  def git_head(root)
    out, status = Open3.capture2e('git', '-C', root, 'rev-parse', 'HEAD')
    raise Refused, 'cannot resolve HEAD' unless status.success?

    out.strip
  end

  def recorded(root, sha, text)
    repo = CfProjectIdentity.for(root).id
    ChangeRunScriptStore.new(root: File.join(@home, '.claude', 'cf', 'change', ChangeRunScriptStore::DIR))
                        .lookup(repo: repo, script_sha256: Digest::SHA256.hexdigest(text.b), sha: sha)
  end

  def approved_request(proof, root, sha, path, text)
    verify(proof, root, sha, path, text)
    consume(proof)
    request_id(proof)
  end

  # No recorded approval: only an active autopilot that lists run_script runs it.
  def autopilot_request(root, sha, path, text)
    id = @autopilot.call(root, "run #{File.basename(path)} at #{sha[0, 12]}", text)
    raise Refused, "no phone-approved run is recorded for this exact script at commit #{sha[0, 12]}; " \
                   'request one (approval_console.rb request --type run-script --script <path> --title <t>) and record it' unless id

    @verified_profile = @profile || @env['AWS_PROFILE']
    ledger_row(id, text)
    "autopilot:#{id}"
  end

  def autopilot_waiver(root, detail, text)
    ChangeAutopilot.waive!('run_script', project: root, guard: 'cf_run_approved', detail: detail, command: text)
  end

  # The run-ledger names the autopilot where an approved run names a request id.
  def ledger_row(autopilot_id, text)
    FileUtils.mkdir_p(ledger_dir)
    now = @clock.call
    name = "autopilot-#{autopilot_id[0, 16]}-#{Digest::SHA256.hexdigest(text.b)[0, 16]}-#{now.to_i}"
    File.write(File.join(ledger_dir, name), JSON.generate('autopilot' => autopilot_id, 'ran_at' => now.utc.iso8601))
  end

  def verify(proof, root, sha, path, text)
    signed = ApprovalConsole::Canonical.parse(proof.is_a?(Hash) ? proof['body'] : nil)
    expected = { 'type' => 'run-script', 'repo' => CfProjectIdentity.for(root).id, 'sha' => sha, 'profile' => signed['profile'],
                 'script_sha256' => Digest::SHA256.hexdigest(text.b), 'script_path' => path, 'script_text' => text,
                 'title' => signed['title'], 'account' => signed['account'] }
    authority = @authority || ApprovalConsole::Recorder.authority_for(root)
    check = ApprovalConsole::ProofCheck.new(level: 'passkey', store: store, pins: authority.policy&.approval_pins, now: @clock.call)
    problem = check.receipt_problem(proof, expected)
    raise Refused, "the recorded receipt is refused: #{problem}" if problem
    raise Refused, 'the receipt is 15 minutes old or older (or dated in the future); request a new approval' unless
      ApprovalConsole::ProofCheck.fresh?(proof, at: @clock.call, max_age: MAX_AGE)

    verify_account(signed['account'], signed['profile'])
  rescue ApprovalConsole::Canonical::Invalid => e
    raise Refused, "the recorded receipt is malformed: #{e.message}"
  rescue ChangePolicy::Unreadable => e
    raise Refused, "cannot read the authoritative approval policy (#{e.message})"
  end

  def verify_account(signed, signed_profile)
    return if signed.nil?

    profile = @profile || signed_profile || @env['AWS_PROFILE']
    @verified_profile = profile
    current = @account ? @account.call(profile) : current_account(profile)
    return if current == signed

    raise Refused, "the receipt is for AWS account #{signed} but the current account is #{current.inspect}" if current
    raise Refused, "the receipt is for AWS account #{signed} but no AWS identity could be resolved (profile: #{profile || 'none'}); " \
                   'pass --profile NAME (or request with --profile), or set AWS_PROFILE, and log in to it'
  end

  # Asked of the AWS profile the script will use: --profile, else the profile
  # the request was made with (signed in the receipt), else AWS_PROFILE.
  def current_account(profile)
    cmd = [ 'aws', 'sts', 'get-caller-identity', '--query', 'Account', '--output', 'text' ]
    cmd.push('--profile', profile) if profile
    out, status = Open3.capture2e(*cmd)
    status.success? ? out.strip : nil
  rescue SystemCallError
    nil
  end

  def request_id(proof) = ApprovalConsole::Canonical.parse(proof['body'])['request_id']

  # The local ledger first (an exclusive create, so two runners cannot both
  # take it), then the console. A console that cannot be reached releases the
  # ledger mark; a refusal from it (already consumed, expired) keeps it.
  def consume(proof)
    id = request_id(proof)
    FileUtils.mkdir_p(ledger_dir)
    mark = File.join(ledger_dir, id)
    begin
      File.open(mark, File::WRONLY | File::CREAT | File::EXCL) { |f| f.write(JSON.generate('consumed_at' => @clock.call.utc.iso8601)) }
    rescue Errno::EEXIST
      raise Refused, 'this receipt was already used; request a new approval'
    end
    console_consume(id, mark)
  end

  def console_consume(id, mark)
    client = @client || ApprovalConsole::Client.for(store) or raise Refused, 'no console is configured, so the receipt cannot be consumed'
    client.consume(id)
  rescue ApprovalConsole::Client::Unreachable => e
    FileUtils.rm_f(mark)
    raise Refused, "the console is unreachable (#{e.message}); nothing ran. Retry when it is back, or run the manual script by hand"
  rescue ApprovalConsole::Client::Refused => e
    raise Refused, "the console refused to consume the receipt (#{e.code}); request a new approval"
  end

  def store = @store ||= ApprovalConsole::LocalStore.new

  # Runs a private copy of the bytes that were verified, never the queue path:
  # the file there can be edited or replaced while the policy fetch, the account
  # check and the console call are in flight.
  def run_snapshot(path, text, root, sha, request_id)
    Dir.mktmpdir('cf-run-approved') do |dir|
      File.chmod(0o700, dir)
      copy = File.join(dir, File.basename(path))
      File.write(copy, text)
      File.chmod(0o700, copy)
      @runner.call(copy, root, sha, request_id)
    end
  end

  # No tty: stdin is closed at once so a script that reads it sees EOF. Output
  # streams through line by line.
  def spawn_script(path, root, sha, request_id)
    cmd = case File.extname(path)
    when '.sh' then [ 'bash', path ]
    when '.rb' then [ RbConfig.ruby, path ]
    else [ path ]
    end
    env = { 'CF_APPROVED_COMMIT' => sha, 'CF_APPROVED_REQUEST' => request_id }.merge(aws_identity_env)
    Open3.popen2e(env, *cmd, chdir: root) do |stdin, out, wait|
      stdin.close
      out.each_line { |line| @out.print(line) }
      wait.value.exitstatus || 1
    end
  end

  # The account check ran against the resolved profile, so the script gets that
  # profile and no other credential source: ambient keys or another default
  # profile could point it at a different account than the one verified.
  AWS_AMBIENT = %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE].freeze

  def aws_identity_env
    return {} unless @verified_profile

    AWS_AMBIENT.to_h { |name| [ name, nil ] }.merge('AWS_PROFILE' => @verified_profile)
  end

  def finish(path, text, status)
    return success(path, text) if status.zero?

    @err.puts "[cf_run_approved] #{File.basename(path)} exited #{status}. The receipt is consumed; request a new approval to retry."
    status
  end

  # The queued file moves to done/ only while it still holds the approved bytes;
  # a changed one stays put for a human to look at.
  def success(path, text)
    unless File.file?(path) && File.binread(path) == text.b
      @err.puts "[cf_run_approved] #{File.basename(path)} changed after it was approved; left in the queue."
      return 0
    end

    done = File.join(queue_dir, 'done')
    FileUtils.mkdir_p(done)
    FileUtils.mv(path, File.join(done, File.basename(path)))
    @out.puts "[cf_run_approved] ran #{File.basename(path)}; moved to queue/done/."
    0
  end
end

if __FILE__ == $PROGRAM_NAME
  repo = Dir.pwd
  profile = nil
  OptionParser.new do |o|
    o.on('--repo PATH') { |value| repo = File.expand_path(value) }
    o.on('--profile NAME') { |value| profile = value }
  end.parse!
  script = ARGV.first
  abort 'usage: cf_run_approved.rb [--repo PATH] [--profile AWS_PROFILE] <queued-script>' unless script
  exit CfRunApproved.new(profile: profile).run(script, repo: repo)
end
