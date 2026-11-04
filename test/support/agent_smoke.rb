#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "open3"
require "timeout"
require "rbconfig"
require "optparse"
require "stringio"
require "time"
require_relative "../../install"

# Opt-in model turn in an isolated HOME. It cannot publish to a real remote.
# Auth is copied locally for the duration of the run, never printed or retained.
class AgentSmoke
  HOSTS = {
    "codex" => [ "codex", "exec", "--sandbox", "read-only", "--dangerously-bypass-hook-trust", "--json" ],
    "claude" => [ "claude", "-p", "--output-format", "json", "--permission-mode", "plan" ],
    "pi" => [ "pi", "--mode", "json", "-p" ],
    "copilot" => [ "copilot", "-p" ],
    "opencode" => [ "opencode", "run" ]
  }.freeze

  def run(host:, output:, timeout: 90)
    argv = HOSTS.fetch(host)
    executable = ENV.fetch("PATH").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, argv.first)) }
    return report(output, host: host, status: "not-run", reason: "host binary is unavailable") unless executable

    original_home = Dir.home
    Dir.mktmpdir("cf-model-smoke-") do |dir|
      home, project = File.join(dir, "home"), File.join(dir, "project")
      FileUtils.mkdir_p([ home, project ])
      paths = Install::Paths.new(repo: File.expand_path("../..", __dir__), home: home)
      # Installer stdout is setup detail, not model verification evidence.
      installer_log = StringIO.new
      previous_stdout = $stdout
      begin
        $stdout = installer_log
        Install::Installer.new(paths: paths, ruby: RbConfig.ruby).install
      ensure
        $stdout = previous_stdout
      end
      auth_ready = copy_auth(host, original_home, home)
      return report(output, host: host, status: "not-run", reason: "isolated host authentication is unavailable") unless auth_ready

      system("git", "init", "-q", "-b", "feature", project, exception: true)
      compiler = SkillCompiler.new(host: host)
      prompt = "#{compiler.invocation('local-only')} State the active merge mode and acknowledge you will not push or open a PR. Do not modify files or do any other work."
      env = { "HOME" => home, "CODEX_HOME" => File.join(home, ".codex"),
              "CF_STATE_HOME" => File.join(home, ".local/state/change-fabric"),
              "CF_RUNTIME_BIN" => paths.runtime_bin }
      out, err, code = bounded(env, [ *argv, prompt ], project, timeout)
      states = Dir.glob(File.join(home, ".local/state/change-fabric/sessions", host, "**", "*.json")).map { |file| JSON.parse(File.read(file)) }
      persisted = states.any? { |state| state["mode"] == "local-only" }
      passed = code == 0 && persisted && out.include?("local-only")
      version, = Open3.capture2(argv.first, "--version", err: File::NULL)
      report(output, host: host, version: version.strip, status: passed ? "passed" : "failed",
        scope: "explicit local-only invocation, model acknowledgement, native hook persistence",
        persisted: persisted, exit_status: code, stdout: out, stderr: err,
        limits: "Does not establish all skill behavior, native slash aliases, or release-gate enforcement.")
    end
  end

  private

  def copy_auth(host, source, home)
    # Other authentication methods are host-specific; do not fall back to a
    # user's live HOME just to turn an unavailable smoke check into a success.
    return false unless host == "codex"

    auth = File.join(source, ".codex", "auth.json")
    return false unless File.file?(auth)

    FileUtils.mkdir_p(File.join(home, ".codex"))
    dest = File.join(home, ".codex", "auth.json")
    FileUtils.cp(auth, dest)
    File.chmod(0o600, dest)
    File.write(File.join(home, ".codex", "config.toml"), "[features]\nhooks = true\n")
    true
  end

  def bounded(env, argv, project, timeout)
    Open3.popen3(env, *argv, chdir: project, pgroup: true) do |input, out, err, wait|
      input.close
      readers = [ Thread.new { out.read }, Thread.new { err.read } ]
      begin
        Timeout.timeout(timeout) { wait.value }
        [ readers[0].value, readers[1].value, wait.value.exitstatus ]
      rescue Timeout::Error
        Process.kill("KILL", -wait.pid)
        readers.each(&:value)
        [ "", "host smoke timed out", 124 ]
      end
    end
  end

  def report(path, **data)
    data = { schema_version: 1, recorded_at: Time.now.utc.iso8601, evidence: "live-model" }.merge(data)
    File.write(path, "#{JSON.pretty_generate(data)}\n", mode: "w", perm: 0o600)
    puts "#{data[:host]}: #{data[:status]} (#{path})"
    data[:status]
  end
end

if __FILE__ == $PROGRAM_NAME
  options = { timeout: 90 }
  OptionParser.new do |parser|
    parser.on("--host HOST", AgentSmoke::HOSTS.keys) { |host| options[:host] = host }
    parser.on("--output PATH") { |path| options[:output] = path }
    parser.on("--timeout SECONDS", Integer) { |seconds| options[:timeout] = seconds }
  end.parse!
  abort "Usage: ruby test/support/agent_smoke.rb --host HOST --output PATH [--timeout SECONDS]" unless options[:host] && options[:output]
  exit(AgentSmoke.new.run(**options) == "failed" ? 1 : 0)
end
