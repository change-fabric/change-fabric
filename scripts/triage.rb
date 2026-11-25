#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'triage/paths'
require_relative 'triage/sources'
require_relative 'triage/publisher'
require_relative 'ctx_expiry'

# Scheduled triage for long-running epic and roadmap execution.
#
#   triage.rb report [--json]    pure read of live state; never writes
#   triage.rb publish [--json]   the model-free tick body: publishes report.json
#                                and snapshot.json, advancing the generation by
#                                one; installs no timer
#   triage.rb expire [--apply] [--json] [--project DIR]
#                                completion-driven ctx expiry for one project
#                                (default the current directory); a dry run
#                                unless --apply, which archives only what state
#                                proves done and queues the ambiguous
#
# Later phases add tick, install, reassign and answer.
module Triage
  module CLI
    USAGE = 'usage: triage.rb report [--json] | publish [--json] | expire [--apply] [--json] [--project DIR]'

    def self.run(argv, out: $stdout, err: $stderr, now: Time.now.utc, sources: {})
      command, *rest = argv
      json = rest.delete('--json')
      return expire(rest, out, err, json, sources) if command == 'expire'
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

    def self.expire(rest, out, err, json, sources)
      apply = rest.delete('--apply')
      index = rest.index('--project')
      project = index && rest[index + 1]
      rest.slice!(index, 2) if index
      return usage(err) unless rest.empty? && (index.nil? || project)

      verdicts = Expire.build(project || Dir.pwd, sources)
      plan = verdicts.plan
      applied = apply ? verdicts.apply(plan) : nil
      summary = CtxExpiry.summary(plan, applied: applied)
      out.puts(json ? JSON.pretty_generate(summary) : Expire.text(summary))
      applied && applied['results'].any? { |row| row['outcome'] == 'error' } ? 1 : 0
    rescue CtxPaths::NotAProject => e
      err.puts("triage: #{e.message}")
      1
    end

    # Builds the expirer; tests inject `expirer:` to avoid the real stores.
    module Expire
      def self.build(cwd, sources) = sources[:expirer] || CtxExpiry::Expirer.new(cwd: File.expand_path(cwd))

      def self.text(summary)
        lines = [ summary['dry_run'] ? 'ctx expiry (dry run)' : 'ctx expiry (applied)' ]
        summary['pointers'].each { |row| lines << "  #{row['action']} #{row['name']} (#{row['reason']})" }
        Array(summary['results']).each { |row| lines << "  #{row['outcome']} #{row['name']}" }
        lines << "  #{summary['counts'].map { |key, count| "#{key}=#{count}" }.join(' ')}"
        lines.join("\n")
      end
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
