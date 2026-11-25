# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'paths'
require_relative 'heartbeat'
require_relative 'snapshot'
require_relative 'sources'

module Triage
  # The model-free tick body: publish `report.json` and `snapshot.json` with the
  # generation advanced by exactly one. Under an exclusive file lock it builds
  # the new report, stages every file as a temp sibling, and only then renames
  # (old report to report.prev.json, snapshot, then report.json last). A build
  # or staging failure renames nothing, so the previous valid report and
  # baseline stay in place. "What changed" diffs against the previous published
  # report, which is why only publish rotates the baseline.
  module Publisher
    Published = Struct.new(:generation, :report, :report_path, :snapshot_path, keyword_init: true)

    def self.publish(root: Paths.root, now: Time.now.utc, **sources)
      FileUtils.mkdir_p(root)
      File.open(Paths.lock_file(root), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        publish_locked(root, now, sources)
      end
    end

    def self.publish_locked(root, now, sources)
      old = Sources.previous(Paths.report_file(root))
      generation = (old ? old['generation'].to_i : 0) + 1
      host = Paths.host
      Heartbeat.write(Paths.heartbeat_dir(root), host || 'local', now: now, generation: generation)
      inputs = Sources.collect(root: root, now: now, host: host, **sources)
      report = Report.new(**inputs).build
      report['generation'] = generation
      snapshot = Snapshot.build(host: host || 'local', generation: generation, now: now, report: report, host_map: inputs[:host_map])
      commit(root, old, report, snapshot)
      Published.new(generation: generation, report: report, report_path: Paths.report_file(root),
                    snapshot_path: Paths.snapshot_file(root))
    end

    def self.commit(root, old, report, snapshot)
      staged = []
      files = { Paths.report_file(root) => JSON.pretty_generate(report), Paths.snapshot_file(root) => JSON.pretty_generate(snapshot) }
      files[Paths.prev_report_file(root)] = JSON.pretty_generate(old) if old
      files.each { |path, content| staged << stage(path, content) }
      order = [ Paths.prev_report_file(root), Paths.snapshot_file(root), Paths.report_file(root) ]
      order.each { |path| File.rename("#{path}.next", path) if File.exist?("#{path}.next") }
    ensure
      staged.to_a.each { |tmp| FileUtils.rm_f(tmp) }
    end

    def self.stage(path, content)
      tmp = "#{path}.next"
      File.write(tmp, content)
      tmp
    end
  end
end
