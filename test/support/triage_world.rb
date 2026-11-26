# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "yaml"
require_relative "triage_fakes"
require_relative "../../scripts/triage/tick"
require_relative "../../scripts/triage/launcher"

# A disposable triage root for the acting tests: a hosts.yml whose repos have
# real checkout directories, fixture reports, recording fakes for the detached
# job and the autopilot reader, and the stub `claude` and `gh` on PATH.
class TriageWorld
  BIN = File.expand_path("bin", __dir__)
  Auto = Struct.new(:id, :expires_at)

  attr_reader :root, :repos, :detached, :inbox_root

  def initialize(repos: { "acme/api" => "mini" }, fixture: "ready")
    @root = Dir.mktmpdir("triage-root")
    @inbox_root = Dir.mktmpdir("triage-inbox")
    @fixture = fixture
    @repos = repos.to_h { |repo, host| [ repo, [ host, Dir.mktmpdir("triage-repo") ] ] }
    @detached = []
    @window = Auto.new("a" * 64, TriageFakes::NOW + 7200)
    write_map
  end

  def write_map(versions: {})
    body = { "repos" => @repos.to_h { |repo, (host, path)| [ repo, { "host" => host, "assignment_version" => versions.fetch(repo, 1), "path" => path } ] } }
    File.write(File.join(@root, "hosts.yml"), YAML.dump(body))
  end

  def close
    [ @root, @inbox_root, *@repos.values.map(&:last) ].each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def journal(now: TriageFakes::NOW) = Triage::Journal.new(root: @root, clock: -> { now })
  def inbox = LeasedInbox.new(root: @inbox_root, clock: -> { TriageFakes::NOW })
  def cap(limit = 20, now: TriageFakes::NOW) = Triage::UnitCap.new(root: @root, clock: -> { now }, cap: limit)
  def path(repo) = @repos.fetch(repo).last

  # Autopilot window: open (default), or closed with window(false).
  def window(open = true)
    @reader = open ? ->(_path) { [ @window ] } : ->(_path) { [] }
  end

  def grant(host = "mini")
    Triage::Grant.new(reader: @reader || ->(_path) { [ @window ] }, machine: host)
  end

  def liveness(boot: "boot-2", pid_start: ->(_pid) { :absent }, listing: Triage::Liveness::Agents.new(ok: true, complete: true, sessions: []))
    Triage::Liveness.new(host: "h", boot_id: -> { boot }, pid_start: pid_start, agents: -> { listing })
  end

  def sources(stack_root: File.join(TriageFakes::FIXTURES, "partial", "stacks"), gh: nil)
    table = gh || TriageFakes.json(File.join(TriageFakes::FIXTURES, "partial", "gh.json"), {})
    { gh: TriageFakes::Gh.new(table), epic_gh: TriageFakes::EpicGh.new({}), decisions: [], stack_root: stack_root,
      plans_root: File.join(TriageFakes::FIXTURES, @fixture, "plans"), pull: ->(_target) { raise "no remote pull in tests" } }
  end

  def detach = ->(**args) { @detached << args; true }

  def tick(now: TriageFakes::NOW, dry_run: false, host: "mini", sources: self.sources, cap: self.cap, **extra)
    Triage::Tick.new(root: @root, host: host, now: now, dry_run: dry_run, sources: sources, journal: journal(now: now), cap: cap,
                     inbox: inbox, liveness: liveness, grant: grant(host), detach: detach, expirer: ->(_dir) { NoExpiry.new },
                     **extra).run
  end

  class NoExpiry
    def plan = []
    def apply(_plan) = { "results" => [], "queued" => [] }
  end

  def stub_path = "#{BIN}:#{ENV.fetch('PATH')}"
end
