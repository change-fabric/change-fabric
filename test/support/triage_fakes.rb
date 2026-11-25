# frozen_string_literal: true

require "json"
require_relative "../../scripts/triage/gh_live"
require_relative "../../scripts/triage/host_map"
require_relative "../../scripts/triage/sources"
require_relative "../../scripts/triage/report"

# Fixture-driven stand-ins for the report's two network sources, plus a loader
# that assembles Report inputs from one directory under test/fixtures/triage.
module TriageFakes
  FIXTURES = File.expand_path("../fixtures/triage", __dir__)
  NOW = Time.utc(2026, 11, 25, 12, 0, 0)

  # Replays gh.json: { "<repo>#<number>": { state, ci, clean, unresolved_threads } }.
  # The string "unavailable" in place of a hash raises the network error.
  class Gh
    def initialize(table) = @table = table

    def pr(repo, number)
      row = @table.fetch("#{repo}##{number}") { raise Triage::GhLive::QueryError, "no fixture for #{repo}##{number}" }
      raise Triage::GhLive::Unavailable, "gh #{repo}##{number}: could not resolve host" if row == "unavailable"

      Triage::GhLive::Facts.new(state: row["state"], ci: row["ci"], clean: row["clean"],
                                unresolved_threads: row["unresolved_threads"])
    end
  end

  # Replays trailers.json: { "<repo> <ref>": [numbers] }; absent means none.
  class EpicGh
    def initialize(table) = @table = table
    def pr_search_trailer(repo, ref) = @table.fetch("#{repo} #{ref}", [])
  end

  def self.json(path, default)
    File.file?(path) ? JSON.parse(File.read(path)) : default
  end

  def self.inputs(name, **overrides)
    dir = File.join(FIXTURES, name)
    findings = []
    map = Triage::HostMap.load(File.join(dir, "hosts.yml"))
    {
      host_map: map, epics: Triage::Sources.epics(File.join(dir, "plans"), findings),
      stacks: Triage::Sources.stacks(File.join(dir, "stacks")),
      gh: Gh.new(json(File.join(dir, "gh.json"), {})), epic_gh: EpicGh.new(json(File.join(dir, "trailers.json"), {})),
      decisions: json(File.join(dir, "decisions.json"), []), now: NOW, findings: findings
    }.merge(overrides)
  end

  def self.build(name, **overrides) = Triage::Report.new(**inputs(name, **overrides)).build
end
