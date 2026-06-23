#!/usr/bin/env ruby
# frozen_string_literal: true
# PST PreToolUse guard. Deterministic enforcement, inert unless this session is
# armed. Policies:
#   1. No em dash (U+2014) in Write/Edit content or git commit messages.
#   2. Merge guard: block a direct `gh pr merge` unless CI is fully green (rule 5)
#      AND an adversarial review is recorded for the head commit (rule 7).
#      `--auto` defers to GitHub. Overrides: PST_ALLOW_RED_MERGE=1 (CI),
#      PST_ALLOW_UNREVIEWED_MERGE=1 (review).
require_relative 'pst_common'
require 'open3'
require 'timeout'

def capture(*argv, dir:)
  Timeout.timeout(25) { Open3.capture2e(*argv, chdir: dir) }
end

def resolve_dir(cwd)
  cwd && File.directory?(cwd) ? cwd : Dir.pwd
end

def head_sha(pr, dir)
  if pr
    out, st = capture('gh', 'pr', 'view', pr, '--json', 'headRefOid', '-q', '.headRefOid', dir: dir)
    return out.strip if st.success?
  end
  out, st = capture('git', 'rev-parse', 'HEAD', dir: dir)
  st.success? ? out.strip : ''
end

# Block a direct `gh pr merge` unless green CI and a recorded review. Returns to allow.
def merge_guard(cmd, cwd)
  return unless cmd =~ /\bgh\s+pr\s+merge\b/
  return if cmd =~ /\s--auto\b/ # auto-merge defers to GitHub's approval + checks gate

  dir = resolve_dir(cwd)
  pr = cmd[%r{\bgh\s+pr\s+merge\b.*?\s(\d+|https?://\S+)}, 1]

  check_ci_gate(pr, dir)
  check_review_gate(pr, dir)
end

# -- private helpers for merge_guard ------------------------------------------

def check_ci_gate(pr_ref, dir)
  return if ENV['PST_ALLOW_RED_MERGE'] == '1'

  argv = ['gh', 'pr', 'checks']
  argv << pr_ref if pr_ref
  begin
    out, status = capture(*argv, dir: dir)
  rescue Timeout::Error
    Pst.deny!('PST merge guard: timed out verifying CI. Rule 5 needs fully green ' \
              'CI. Re-run after CI reports, or set PST_ALLOW_RED_MERGE=1.')
  rescue StandardError => e
    Pst.deny!("PST merge guard: could not verify CI (#{e.class}). Set " \
              'PST_ALLOW_RED_MERGE=1 to override if CI is green.')
  end
  code = status&.exitstatus
  return if code.zero? || out =~ /no check|no checks reported/i

  summary = out.to_s.lines.first(10).map(&:rstrip).join("\n")
  Pst.deny!("PST merge guard: CI is not fully green, rule 5 blocks this merge " \
            "(gh pr checks exit #{code}). Wait for all checks, or set " \
            "PST_ALLOW_RED_MERGE=1.\n#{summary}")
end

def check_review_gate(pr_ref, dir)
  return if ENV['PST_ALLOW_UNREVIEWED_MERGE'] == '1'

  sha = head_sha(pr_ref, dir)
  return if Pst.reviewed?(sha)

  Pst.deny!("PST review gate: no adversarial review recorded for commit " \
            "#{sha.empty? ? '(unknown)' : sha[0, 12]} (rule 7). Run " \
            '/pst:adversarial-review or /pst:code-review, record it with ' \
            "`pst-reviewed.rb mark`, then merge. Override PST_ALLOW_UNREVIEWED_MERGE=1.")
end

# Local-only mode (merge mode 4): block any command that mutates remote GitHub
# state (push a branch, create/merge/ready/edit/close a PR or issue, post a
# comment). Read commands (gh pr view|checks|list) are untouched. Work stays in
# local worktrees and commits. Override once with PST_ALLOW_REMOTE=1.
def local_guard(cmd)
  return unless Pst.local_only?
  return if ENV['PST_ALLOW_REMOTE'] == '1'

  remote =
    cmd =~ /\bgit\s+push\b/ ||
    cmd =~ /\bgh\s+pr\s+(create|merge|ready|edit|comment|close|reopen)\b/ ||
    cmd =~ /\bgh\s+issue\s+(create|edit|comment|close|reopen)\b/
  return unless remote

  Pst.deny!('PST local-only mode (merge mode 4): no remote GitHub mutations this ' \
            'session. This command pushes a branch or changes a remote PR or issue. ' \
            'Keep work in local worktrees and commits. To go remote, re-invoke /pst ' \
            'and pick another merge mode, or override once with PST_ALLOW_REMOTE=1.')
end

# Block `git push` to the repo's default branch. Fires in all merge modes except
# local-only (local_guard already covers that). Override: PST_ALLOW_MAIN_PUSH=1.
def push_guard(cmd, cwd)
  return unless cmd =~ /\bgit\s+push\b/
  return if Pst.local_only?
  return if ENV['PST_ALLOW_MAIN_PUSH'] == '1'

  dir = resolve_dir(cwd)
  d = Pst.default_branch(dir)
  b = Regexp.escape(d)

  explicit_dest = (cmd =~ /:#{b}(?:\s|\z)/) || (cmd =~ /\bgit\s+push\b[^|;&]*\s#{b}(?:\s|\z)/)
  bare = cmd !~ /:/ && cmd !~ /\bgit\s+push\b[^|;&]*\s#{b}(?:\s|\z)/
  targets_default = explicit_dest || (bare && Pst.current_branch(dir) == d)

  return unless targets_default

  Pst.deny!("PST push guard: pushing directly to the default branch '#{d}' is not " \
            'allowed. Open a PR from a feature branch and merge through the ' \
            "gates (rules 5/7) instead. Override once with PST_ALLOW_MAIN_PUSH=1.")
end

Pst.allow! unless Pst.armed?

tool = Pst.payload['tool_name'].to_s
ti = Pst.payload['tool_input'] || {}

case tool
when 'Write', 'Edit', 'MultiEdit', 'NotebookEdit'
  texts = %w[content new_string new_source].map { |k| ti[k] }.select { |v| v.is_a?(String) }
  (ti['edits'] || []).each { |e| texts << e['new_string'] if e.is_a?(Hash) && e['new_string'].is_a?(String) }
  if texts.any? { |t| t.include?(Pst::EM) }
    Pst.deny!('PST mode: the em dash (U+2014) is not allowed. Rewrite with commas, ' \
              'colons, parentheses, or two sentences before writing this file.')
  end
when 'Bash'
  cmd = ti['command'].to_s
  if cmd.include?('git commit') && cmd.include?(Pst::EM)
    Pst.deny!('PST mode: em dash (U+2014) detected in a git commit message. ' \
              'Rephrase the message without em dashes.')
  end
  local_guard(cmd)
  push_guard(cmd, Pst.payload['cwd'])
  merge_guard(cmd, Pst.payload['cwd'])
when 'Agent', 'Task'
  # Rule 2: spawns must set an explicit model. Effort is not a spawn parameter,
  # so only model is enforceable. Denies only when model is absent, so it can
  # never block a spawn that does set one.
  if ti['model'].to_s.empty? && ENV['PST_ALLOW_DEFAULT_MODEL'] != '1'
    Pst.deny!('PST tier guard (rule 2): set an explicit model on the agent. Use ' \
              'sonnet for implementers, haiku for trivial well-defined mechanical ' \
              'work, opus only for deep audits. Re-spawn with model set. Override ' \
              'PST_ALLOW_DEFAULT_MODEL=1.')
  end
end

Pst.allow!
