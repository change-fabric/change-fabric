#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'ctx_store'
require_relative 'stack_store'
require_relative 'epic_store'
require_relative 'epic_status'
require_relative 'epic_gh'
require_relative 'plan_paths'
require_relative 'inbox_store'

# Completion-driven ctx expiry. A ctx pointer is a live, active ctx doc that
# names the work it tracks, and it should leave the live set when state proves
# that work finished, not when it ages out (CtxRetention keeps its own 90 day
# and 25 doc rules, unchanged). Two links exist:
#
#   stack  the doc is named `stack-<slug>`; evidence is the stack record
#   epic   the body has a line `Epic-Node: <epic-slug> <plan_id>#Phase N`;
#          evidence is that node's state from EpicStatus
#
# Decision table (the first matching row wins):
#
#   pinned (`pinned: true` frontmatter)           keep, never touched
#   no stack or epic link                         keep (age rule only)
#   any link: record missing or unreadable        queue
#   any link: stack PR list empty                 queue (never done)
#   stack only: all merged / any open             archive / keep
#   epic only: node done / not done               archive / keep
#   both: stack all merged and node done          archive
#   both: one done and one not                    queue (disagree)
#   both: neither done                            keep
#
# Plan is a pure read. Apply archives with CtxStore#archive (restorable, so
# `unarchive` reverses it), and before each archive, under the store lock,
# re-reads the pin and recomputes the evidence; any change since the plan
# skips that pointer. A queued pointer becomes a `ctx_ambiguous` item in
# cf:inbox. An archive that raises stops the batch: earlier archives stay,
# the rest are reported `not_attempted`, and a rerun is idempotent.
module CtxExpiry
  EPIC_LINK = /^Epic-Node:[ \t]*(\S+)[ \t]+(\S[^\n]*?)[ \t]*$/
  STACK_PREFIX = 'stack-'

  Verdict = Data.define(:name, :action, :reason, :fingerprint) do
    def to_h = { 'name' => name, 'action' => action.to_s, 'reason' => reason }
  end

  # What state says about one link: :done, :open, or :queue with a reason.
  Finding = Data.define(:state, :reason, :version)

  # Reads link evidence. A fresh instance re-reads everything (no memo across
  # instances), which is how apply revalidates just before an archive.
  class Evidence
    def initialize(cwd:, plans_root: PlanPaths.root, epic_runner: nil)
      @cwd = cwd
      @plans_root = plans_root
      @epic_runner = epic_runner || ->(epic) { EpicStatus.run(epic, EpicGh::Cli.new) }
      @epics = {}
    end

    def stack(slug)
      record = StackStore.for_dir(@cwd, slug).read
      return Finding.new(:queue, 'stack_record_missing', nil) unless record

      prs = Array(record['prs'])
      version = Digest::SHA256.hexdigest(JSON.generate(prs.map { |pr| [ pr['number'], pr['state'] ] }))
      return Finding.new(:queue, 'stack_pr_list_empty', version) if prs.empty?

      if prs.all? { |pr| pr['state'] == 'merged' }
        Finding.new(:done, 'stack_all_merged', version)
      else
        Finding.new(:open, 'stack_open', version)
      end
    end

    def epic(slug, node_id)
      nodes = epic_nodes(slug)
      return Finding.new(:queue, 'epic_record_missing', nil) unless nodes

      node = nodes.find { |candidate| candidate.id == node_id }
      return Finding.new(:queue, 'epic_node_missing', nil) unless node

      version = "#{node.id}=#{node.state}"
      case node.state
      when 'done' then Finding.new(:done, 'epic_node_done', version)
      when 'unknown' then Finding.new(:queue, 'epic_node_unknown', version)
      else Finding.new(:open, 'epic_node_not_done', version)
      end
    end

    private

    def epic_nodes(slug)
      return @epics[slug] if @epics.key?(slug)

      @epics[slug] = load_nodes(slug)
    end

    def load_nodes(slug)
      path = EpicStore.path_for(slug, root: @plans_root)
      return nil unless File.file?(path)

      epic = EpicStore.load(path, plans_root: @plans_root)
      epic.problems.empty? ? @epic_runner.call(epic) : nil
    rescue StandardError
      nil
    end
  end

  # Turns one pointer doc plus evidence into a Verdict.
  module Decide
    module_function

    def call(doc, front, evidence)
      return Verdict.new(doc.name, :keep, 'pinned', nil) if pinned?(front)

      slug = doc.name.start_with?(STACK_PREFIX) ? doc.name.delete_prefix(STACK_PREFIX) : nil
      link = EPIC_LINK.match(doc.body)
      return Verdict.new(doc.name, :keep, 'no_link', nil) if slug.nil? && link.nil?

      findings = []
      findings << evidence.stack(slug) if slug && !slug.empty?
      findings << evidence.epic(link[1], link[2]) if link
      verdict(doc.name, findings)
    end

    def pinned?(front) = front.is_a?(Hash) && front['pinned'] == true

    def verdict(name, findings)
      fingerprint = Digest::SHA256.hexdigest(findings.map { |f| "#{f.reason}:#{f.version}" }.join('|'))
      queued = findings.find { |f| f.state == :queue }
      return Verdict.new(name, :queue, queued.reason, fingerprint) if queued

      states = findings.map(&:state).uniq
      return Verdict.new(name, :queue, 'stack_and_epic_disagree', fingerprint) if states.size > 1

      done = states.first == :done
      action = done ? :archive : :keep
      return Verdict.new(name, action, findings.first.reason, fingerprint) if findings.size == 1

      Verdict.new(name, action, done ? 'stack_and_epic_done' : 'stack_and_epic_open', fingerprint)
    end
  end

  class Expirer
    def initialize(cwd:, evidence_factory: nil, home: Dir.home, store: nil, queue: InboxQueue.method(:queue))
      @cwd = cwd
      @evidence_factory = evidence_factory || -> { Evidence.new(cwd: cwd) }
      @store = store || CtxStore.new(cwd: cwd, home: home)
      @queue = queue
    end

    # Pure read: one Verdict per live active doc, sorted by name.
    def plan
      evidence = @evidence_factory.call
      pointers.map { |doc| Decide.call(doc, @store.front_of(doc.name), evidence) }
    end

    # Archives every :archive verdict, queues every :queue verdict.
    def apply(verdicts = plan)
      results = []
      stopped = false
      verdicts.each do |verdict|
        next unless verdict.action == :archive

        results << (stopped ? result(verdict, 'not_attempted') : attempt(verdict))
        stopped = true if results.last['outcome'] == 'error'
      end
      queued = verdicts.select { |v| v.action == :queue }.map { |v| queue_one(v) }
      { 'results' => results, 'queued' => queued }
    end

    private

    def pointers
      @store.list(klass: 'active', status: 'active')
    end

    def attempt(verdict)
      @store.with_lock do
        reason = stale_reason(verdict)
        next result(verdict, 'skipped', reason) if reason

        @store.archive(verdict.name, nil, restorable: true)
        result(verdict, 'archived')
      end
    rescue StandardError => e
      result(verdict, 'error', "#{e.class}: #{e.message}")
    end

    # Re-reads the pin and recomputes the evidence under the lock. Anything
    # that moved since the plan skips the pointer rather than archiving on
    # stale proof.
    def stale_reason(verdict)
      doc = @store.read(verdict.name)
      return 'gone' unless doc && doc.klass == 'active' && doc.status == 'active'
      front = @store.front_of(verdict.name)
      return 'pinned' if Decide.pinned?(front)

      fresh = Decide.call(doc, front, @evidence_factory.call)
      return nil if fresh.action == :archive && fresh.fingerprint == verdict.fingerprint

      'evidence_changed'
    end

    def queue_one(verdict)
      queued = @queue.call(verdict, @cwd)
      verdict.to_h.merge('kind' => 'ctx_ambiguous', 'queued' => queued)
    end

    def result(verdict, outcome, detail = nil)
      { 'name' => verdict.name, 'outcome' => outcome, 'detail' => detail }.compact
    end
  end

  # Queues a ctx_ambiguous item in cf:inbox, one file per pointer so a rerun
  # does not duplicate it. Returns true when a new item was written.
  module InboxQueue
    module_function

    def queue(verdict, cwd)
      # InboxStore resolves the roster and inbox from Dir.pwd, so run it from
      # the project being expired, not the caller's directory.
      Dir.chdir(cwd) { queue_in_cwd(verdict, cwd) }
    end

    def queue_in_cwd(verdict, cwd)
      role = InboxStore.humans.first
      return false if role.nil? || InboxStore.no_roster?

      slug = InboxStore.slugify("ctx-ambiguous-#{verdict.name}")
      dir = InboxStore.inbox_dir(role)
      return false if Dir.glob(File.join(dir, "*-#{slug}.md")).any?

      subject = "ctx_ambiguous: #{verdict.name} (#{verdict.reason})"
      body = "Ctx pointer #{verdict.name} in #{cwd} could not be proven done: #{verdict.reason}.\n"
      path = File.join(dir, "#{InboxStore.file_stamp}-triage-#{slug}.md")
      InboxStore.write_item(path, from: 'triage', to: role, subject: subject, refs: verdict.name,
                                  status: 'pending', body: body)
      InboxStore.append_ledger(InboxStore.ledger_line('triage', role, 'pending', slug, subject))
      true
    end
  end

  # JSON-ready summary of a dry run or an apply.
  def self.summary(verdicts, applied: nil)
    shown = verdicts.reject { |v| v.reason == 'no_link' }
    out = { 'dry_run' => applied.nil?, 'pointers' => shown.map(&:to_h),
            'counts' => verdicts.map { |v| v.action.to_s }.tally }
    out.merge!(applied) if applied
    out
  end
end
