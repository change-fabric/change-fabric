#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'triage/paths'
require_relative 'triage/sources'
require_relative 'triage/publisher'
require_relative 'ctx_expiry'
require_relative 'triage/tick'
require_relative 'triage/reassign'
require_relative 'triage/answer'

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
#   triage.rb tick [--dry-run] [--json]
#                                the bounded model-free tick: heartbeat, reconcile
#                                unfinished dispatches, publish, expire, inbox
#                                items, then (not limited, inside an autopilot
#                                window, on this host's repos) detached launches;
#                                --dry-run reads everything and writes nothing
#   triage.rb reassign <repo> --to <host>
#                                quiesced, versioned host reassignment (C8)
#   triage.rb answer <item-id> --text <answer> [--host <host>]
#                                decision write-back, over SSH for a remote host
#   triage.rb run-action <action-id>
#                                internal: the detached one-shot job for a dispatch
#
# A later phase adds install.
module Triage
  module CLI
    USAGE = 'usage: triage.rb report [--json] | publish [--json] | expire [--apply] [--json] [--project DIR] | ' \
            'tick [--dry-run] [--json] | reassign <repo> --to <host> | answer <item-id> --text <answer> [--host <host>]'

    def self.run(argv, out: $stdout, err: $stderr, now: Time.now.utc, sources: {})
      command, *rest = argv
      json = rest.delete('--json')
      return expire(rest, out, err, json, sources) if command == 'expire'
      return tick(rest, out, err, json, now, sources) if command == 'tick'
      return reassign(rest, out, err) if command == 'reassign'
      return answer(rest, out, err) if command == 'answer'
      return run_action(rest, err) if command == 'run-action'
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

    def self.tick(rest, out, err, json, now, sources)
      dry_run = rest.delete('--dry-run')
      return usage(err) unless rest.empty?

      result = Tick.new(now: now, dry_run: !dry_run.nil?, sources: sources.slice(:gh, :epic_gh, :decisions, :plans_root, :stack_root, :pull)).run
      summary = result.summary
      out.puts(json ? JSON.pretty_generate(summary) : tick_text(summary))
      0
    end

    def self.tick_text(summary)
      return "tick skipped: #{summary['skipped']}" if summary['skipped']

      head = "tick #{summary['dry_run'] ? '(dry run) ' : ''}host=#{summary['host'] || 'unset'} units=#{summary['units']} " \
             "cap=#{summary['cap']['used']}/#{summary['cap']['cap']}#{summary['limited'] ? " limited until #{summary['limited']['limited_until']}" : ''}"
      [ head, *summary['actions'].map { |row| "  #{row['kind']} #{row['repo']} #{row['unit']} #{row['reason']}".rstrip } ].join("\n")
    end

    def self.reassign(rest, out, err)
      to_index = rest.index('--to')
      to = to_index && rest[to_index + 1]
      rest.slice!(to_index, 2) if to_index
      return usage(err) unless to && rest.size == 1

      result = Reassign.new.call(rest.first, to)
      (result.ok ? out : err).puts(result.message)
      result.ok ? 0 : 1
    end

    def self.answer(rest, out, err)
      text = take(rest, '--text')
      host = take(rest, '--host')
      return usage(err) unless text && rest.size == 1

      result = Answer.new.call(rest.first, text, host: host)
      (result.ok ? out : err).puts(result.message)
      result.ok ? 0 : 1
    end

    def self.take(rest, flag)
      index = rest.index(flag)
      value = index && rest[index + 1]
      rest.slice!(index, 2) if index
      value
    end

    def self.run_action(rest, err)
      return usage(err) unless rest.size == 1

      Launcher.run(rest.first)
      0
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
