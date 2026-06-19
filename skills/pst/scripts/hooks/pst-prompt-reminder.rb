#!/usr/bin/env ruby
# frozen_string_literal: true
# PST UserPromptSubmit hook: re-inject a compressed doctrine anchor each turn so
# rules cannot drift over a long session. Inert unless armed. Silent for the first
# 3 turns (the model just read SKILL.md fresh). Outputs the short anchor from turn
# 4 onward; every 10th turn appends a reload note. For UserPromptSubmit, plain
# stdout is added to the model context.
require_relative 'pst_common'
require 'fileutils'

Pst.allow! unless Pst.armed?

sid = Pst.session_id

# Per-session turn counter stored at ~/.claude/pst/reminder-turns/<session_id>
turns_dir = File.join(Pst::HOME, 'reminder-turns')
FileUtils.mkdir_p(turns_dir)
counter_file = File.join(turns_dir, sid)
turn = begin
  File.read(counter_file).to_i
rescue StandardError
  0
end + 1
File.write(counter_file, turn.to_s)

# Silent for the first 3 turns -- doctrine is fresh from arming.
Pst.allow! if turn <= 3

anchor = <<~ANCHOR.chomp
  [PST mode armed] Doctrine: SKILL.md. Standing judgment rules (nudged, never blocked):
  1 delegate-by-default: independent, scoped, non-gating work -> background Sonnet worktree agent (use rule-19 pipeline for features/fixes).
  12 de-slop: no filler, hedging, YAGNI in code.
  13 run-to-completion: work through gates autonomously on completion-intent.
  14 prove-it: green + real E2E, never "should work".
  16 brevity: paragraphs <=320 chars, bullets <=160.
  19 pipeline: before writing any file for a feature/fix, run Stage 0 Haiku classifier first -- only a trivial verdict skips the pipeline.
  20 orbstack-docker: dev infra + app servers run as tracked Docker containers, not host-native; session-end reaper cleans up (Caddy/localhost detail in SKILL.md).
  21 gh-cli: use gh for all GitHub work (pr create/view/checks, issue list, release create); never reach for the browser when gh covers it.
  23 smell-pass: after any code file change, run pst-smell.rb + Fowler review (MAINTAINABILITY.md) before stopping.
  Hard rules (em-dash, model-tier, merge-gate, review-gate, open-on-post, local-only) are hook-enforced.
ANCHOR

if (turn % 10).zero?
  puts anchor + "\nFull doctrine: SKILL.md (reload if needed)."
else
  puts anchor
end

# Runs per-turn (not session-start) so agents spawned mid-session see current ledger state.
begin
  in_flight = Pst.in_flight_count(sid)
  if in_flight > 0
    puts "[rule 22] Ledger has #{in_flight} task(s) in flight. " \
         'Pass `pst-ledger.rb context` to new agents; update with `done`/`fail` on completion.'
  end
rescue StandardError
  # skip nudge if the ledger is missing or unparseable
end

# Rule 23: nudge when code files have changed since last commit.
begin
  ledger_path_file = File.join(Pst::HOME, 'ledger-path')
  if File.exist?(ledger_path_file)
    smell_script = File.join(File.dirname(File.read(ledger_path_file).strip), 'pst-smell.rb')
    if File.exist?(smell_script)
      result = `ruby "#{smell_script}" 2>/dev/null`.strip
      if result.start_with?('smell pass: required')
        puts "[rule 23] #{result.lines.first.chomp} -- Fowler smell pass required before stopping (MAINTAINABILITY.md)."
      end
    end
  end
rescue StandardError
  # skip if smell script is unavailable or git not in path
end
