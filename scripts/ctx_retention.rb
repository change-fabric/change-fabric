#!/usr/bin/env ruby
# frozen_string_literal: true

require 'time'
require 'date'
require_relative 'ctx_paths'
require_relative 'ctx_store'

# Decides what in a ctx store is purgeable or needs attention, mirroring
# pst:prune's stance: truth is never a candidate, ephemeral past its ttl is safe
# to drop (the ttl was prior consent), and done/superseded/over-cap/stale active
# docs are surfaced for an explicit decision rather than removed. It also runs a
# structural check (does a doc parse, does its class match its directory). The
# engine only decides; CtxStore applies the delete or archive, so nothing here
# mutates the store.
class CtxRetention
  DEFAULTS = { max_active: 25, stale_after_days: 90, truth_review_days: 365 }.freeze

  # One purge or attention candidate. `action` is what a yes does: :remove drops
  # the doc, :archive compacts then drops it, :review only flags a stale doc.
  Candidate = Data.define(:name, :klass, :status, :reason, :action, :last_touched)

  # A structural problem: a doc did not parse, sits under the wrong class, or
  # carries an invalid status.
  Issue = Data.define(:name, :klass_dir, :problem)

  VALID_STATUS = %w[active done superseded archived].freeze

  def initialize(store:, now: nil, caps: {})
    @store = store
    @now = now
    @caps = DEFAULTS.merge(caps)
  end

  # Ephemeral docs past expiry. Auto-removable: the ttl was the consent.
  def auto_removable
    ephemeral.select { |doc| past_expiry?(doc) }.map { |doc| candidate(doc, 'expired', :remove) }
  end

  # Everything that wants an explicit decision: done/superseded and over-cap
  # active docs (archive), stale active docs (review), and truth docs past their
  # review horizon (review). Deduped by name so a doc that matches twice is
  # offered once. truth never reaches auto_removable, only this review path.
  def needs_review
    (superseded + over_cap + stale + truth_review).uniq(&:name)
  end

  def candidates = (auto_removable + needs_review).uniq(&:name)

  # Structural relevance check over the live classes.
  def issues
    @store.entries.filter_map { |entry| structural_issue(entry) }
  end

  private

  def superseded
    active.select { |doc| %w[done superseded].include?(doc.status) }
          .map { |doc| candidate(doc, doc.status, :archive) }
  end

  def stale
    live_active.select { |doc| stale?(doc) }.map { |doc| candidate(doc, 'stale', :review) }
  end

  def over_cap
    overflow = live_active.size - @caps[:max_active]
    return [] if overflow <= 0

    live_active.sort_by(&:last_touched).first(overflow).map { |doc| candidate(doc, 'over-cap', :archive) }
  end

  # Truth docs untouched past their review horizon. The action is :review, never
  # :remove or :archive: truth is durable, but a fact nobody has touched in a year
  # (or the doc's own review_after) should be reconfirmed or retired by a human.
  def truth_review
    truth.select { |doc| review_due?(doc) }.map { |doc| candidate(doc, 'review-due', :review) }
  end

  def docs = @store.entries.map(&:doc)
  def ephemeral = docs.select { |doc| doc.klass == 'ephemeral' }
  def active = docs.select { |doc| doc.klass == 'active' }
  def truth = docs.select { |doc| doc.klass == 'truth' }
  def live_active = active.select { |doc| doc.status == 'active' }

  def review_due?(doc)
    touched = parse_time(doc.last_touched)
    return false unless touched

    horizon_days = CtxStore::Ttl.days(doc.review_after) || @caps[:truth_review_days]
    (now - touched) > horizon_days * 86_400
  end

  def candidate(doc, reason, action)
    Candidate.new(name: doc.name, klass: doc.klass, status: doc.status,
                  reason:, action:, last_touched: doc.last_touched)
  end

  def past_expiry?(doc)
    return false if doc.expires.to_s.empty?

    Date.parse(doc.expires) < now.to_date
  rescue ArgumentError
    false
  end

  def stale?(doc)
    touched = parse_time(doc.last_touched)
    return false unless touched

    (now - touched) > @caps[:stale_after_days] * 86_400
  end

  def structural_issue(entry)
    doc = entry.doc
    if doc.name.empty?
      Issue.new(name: '(unparsed)', klass_dir: entry.klass_dir, problem: 'missing or unparseable frontmatter')
    elsif doc.klass != entry.klass_dir
      Issue.new(name: doc.name, klass_dir: entry.klass_dir,
                problem: "class '#{doc.klass}' does not match directory '#{entry.klass_dir}'")
    elsif !VALID_STATUS.include?(doc.status)
      Issue.new(name: doc.name, klass_dir: entry.klass_dir, problem: "invalid status '#{doc.status}'")
    end
  end

  def now = @now || Time.now

  def parse_time(value)
    Time.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  # Runs retention over the current project's store: auto-removes expired
  # ephemeral docs, then reports the review set and any structural issues for the
  # agent (the pst:ctx prune verb) to act on. It never archives or removes a
  # review-set doc on its own; that needs an explicit yes.
  class CLI
    def self.run(argv, out: $stdout)
      case argv.first
      when 'prune', nil then prune(out:)
      else out.puts('usage: ctx_retention.rb prune')
      end
    end

    def self.prune(out:, store: CtxStore.new(cwd: Dir.pwd))
      retention = CtxRetention.new(store:)
      removed = retention.auto_removable.filter_map { |candidate| candidate.name if store.delete(candidate.name) }
      report(out, removed, retention.needs_review, retention.issues)
    end

    def self.report(out, removed, review, issues)
      out.puts("[pst:ctx prune] #{Dir.pwd}")
      out.puts("auto-removed (expired ephemeral): #{removed.empty? ? 'none' : removed.join(', ')}")
      out.puts('needs review:')
      out.puts(review.empty? ? '  none' : review.map { |candidate| review_line(candidate) }.join("\n"))
      out.puts('structural issues:')
      out.puts(issues.empty? ? '  none' : issues.map { |issue| "  #{issue.klass_dir}/#{issue.name} - #{issue.problem}" }.join("\n"))
    end

    def self.review_line(candidate)
      "  #{candidate.action} #{candidate.reason} #{candidate.klass}/#{candidate.name} (last touched #{candidate.last_touched.to_s[0, 10]})"
    end
  end
end

CtxRetention::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
