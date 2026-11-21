#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'
require_relative 'approval_console/canonical'
require_relative 'approval_console/client'
require_relative 'approval_console/local_store'
require_relative 'approval_console/proof_check'
require_relative 'approval_console/recorder'
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
#   3. when the receipt names an AWS account, the caller's current account is it;
#   4. the receipt is marked consumed in a local ledger and then on the console,
#      before anything runs, so a reuse is refused whether or not the script
#      succeeds. A console that cannot be reached refuses the run (the ledger
#      mark is released, so a retry is possible once it is back);
#   5. the script runs with no tty and its output streams through; on success it
#      moves to queue/done/.
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
                 out: $stdout, err: $stderr, runner: nil)
    @home = home
    @store = store
    @client = client
    @authority = authority
    @clock = clock
    @account = account
    @out = out
    @err = err
    @runner = runner || method(:spawn_script)
  end

  # Exit status: 0 ran and succeeded, 1 refused, else the script's own status.
  def run(script, repo: Dir.pwd)
    path = File.expand_path(script)
    text = read_script(path)
    root = git_root(repo)
    sha = git_head(root)
    proof = recorded_proof(root, sha, text)
    verify(proof, root, sha, path, text)
    consume(proof)
    status = @runner.call(path, root, sha, request_id(proof))
    finish(path, status)
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

  def recorded_proof(root, sha, text)
    repo = CfProjectIdentity.for(root).id
    record = ChangeRunScriptStore.new(root: File.join(@home, '.claude', 'cf', 'change', ChangeRunScriptStore::DIR))
                                 .lookup(repo: repo, script_sha256: Digest::SHA256.hexdigest(text.b), sha: sha)
    raise Refused, "no phone-approved run is recorded for this exact script at commit #{sha[0, 12]}; " \
                   'request one (approval_console.rb request --type run-script --script <path> --title <t>) and record it' unless record

    record['proof']
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

    verify_account(signed['account'])
  rescue ApprovalConsole::Canonical::Invalid => e
    raise Refused, "the recorded receipt is malformed: #{e.message}"
  rescue ChangePolicy::Unreadable => e
    raise Refused, "cannot read the authoritative approval policy (#{e.message})"
  end

  def verify_account(signed)
    return if signed.nil?

    current = @account ? @account.call : current_account
    raise Refused, "the receipt is for AWS account #{signed} but the current account is #{current.inspect}" unless current == signed
  end

  # Asked of the caller's own AWS profile, the same one the script will use.
  def current_account
    out, status = Open3.capture2e('aws', 'sts', 'get-caller-identity', '--query', 'Account', '--output', 'text')
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

  # No tty: stdin is /dev/null. Output streams through line by line.
  def spawn_script(path, root, sha, request_id)
    cmd = case File.extname(path)
    when '.sh' then [ 'bash', path ]
    when '.rb' then [ RbConfig.ruby, path ]
    else [ path ]
    end
    env = { 'CF_APPROVED_COMMIT' => sha, 'CF_APPROVED_REQUEST' => request_id }
    Open3.popen2e(env, *cmd, chdir: root, in: File::NULL) do |_in, out, wait|
      out.each_line { |line| @out.print(line) }
      wait.value.exitstatus || 1
    end
  end

  def finish(path, status)
    return success(path) if status.zero?

    @err.puts "[cf_run_approved] #{File.basename(path)} exited #{status}. The receipt is consumed; request a new approval to retry."
    status
  end

  def success(path)
    done = File.join(queue_dir, 'done')
    FileUtils.mkdir_p(done)
    FileUtils.mv(path, File.join(done, File.basename(path)))
    @out.puts "[cf_run_approved] ran #{File.basename(path)}; moved to queue/done/."
    0
  end
end

if __FILE__ == $PROGRAM_NAME
  repo = Dir.pwd
  OptionParser.new { |o| o.on('--repo PATH') { |value| repo = File.expand_path(value) } }.parse!
  script = ARGV.first
  abort 'usage: cf_run_approved.rb [--repo PATH] <queued-script>' unless script
  exit CfRunApproved.new.run(script, repo: repo)
end
