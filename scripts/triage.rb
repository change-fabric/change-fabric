#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'triage/paths'
require_relative 'triage/sources'
require_relative 'triage/publisher'

# Scheduled triage for long-running epic and roadmap execution.
#
#   triage.rb report [--json]    pure read of live state; never writes
#   triage.rb publish [--json]   the model-free tick body: publishes report.json
#                                and snapshot.json, advancing the generation by
#                                one; installs no timer
#
# Later phases add expire, tick, install, reassign and answer.
module Triage
  module CLI
    USAGE = 'usage: triage.rb report [--json] | publish [--json]'

    def self.run(argv, out: $stdout, err: $stderr, now: Time.now.utc, sources: {})
      command, *rest = argv
      json = rest.delete('--json')
      return usage(err) unless rest.empty?

      case command
      when 'report' then report(out, json, now, sources)
      when 'publish' then publish(out, json, now, sources)
      else usage(err)
      end
    rescue GhLive::QueryError => e
      err.puts("triage: #{e.message}")
      1
    end

    def self.usage(err)
      err.puts(USAGE)
      2
    end

    def self.report(out, json, now, sources)
      inputs = Sources.collect(root: Paths.root, now: now, **sources)
      report = Report.new(**inputs).build
      if json
        out.puts(JSON.pretty_generate(report))
      else
        Report.render_text(report).each { |line| out.puts(line) }
      end
      0
    end

    def self.publish(out, json, now, sources)
      done = Publisher.publish(now: now, **sources)
      summary = { 'published' => true, 'generation' => done.generation, 'generated_at' => done.report['generated_at'],
                  'units' => done.report['units'].size, 'changed' => done.report['changed'].size,
                  'findings' => done.report['findings'].size }
      out.puts(json ? JSON.pretty_generate(summary) : "published generation #{done.generation} (#{summary['units']} units)")
      0
    end
  end
end

exit(Triage::CLI.run(ARGV)) if __FILE__ == $PROGRAM_NAME
