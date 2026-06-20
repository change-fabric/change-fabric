#!/usr/bin/env ruby
# frozen_string_literal: true
# PST PostCompact hook: after context compaction, recover file-based session
# state. NOTE: PostCompact stdout goes to the user terminal only, not to Claude.
# Claude picks up the ledger state on the next UserPromptSubmit via the rule-22
# nudge in pst-prompt-reminder.rb. This hook handles the file side-effects: if
# the ledger JSON was reaped or lost, re-init it so the next nudge fires cleanly.
require_relative 'pst_common'
require 'rbconfig'

Pst.allow! unless Pst.armed?

sid = Pst.session_id
ledger_path_file = File.join(Pst::HOME, 'ledger-path')

# Re-init the ledger JSON if it was somehow cleaned up (e.g. premature reap).
if File.exist?(ledger_path_file)
  ledger_script = File.read(ledger_path_file).strip
  unless File.exist?(Pst.ledger_path(sid))
    system({'CLAUDE_SESSION_ID' => sid}, RbConfig.ruby, ledger_script, 'init', in: File::NULL) rescue nil
  end
end

lines = ['[PST post-compact] Session is still armed. Doctrine rules remain in effect.']

entries = Pst.load_ledger(sid)
in_flight = entries.select { |e| Pst::IN_FLIGHT_STATUSES.include?(e['status']) }

if in_flight.any?
  lines << "[rule 22] #{in_flight.size} ledger task(s) were in-flight before compact:"
  in_flight.each do |e|
    repo    = e['repo'] || e['worktree'] || '(no repo)'
    intent  = (e['intent'] || e['label'] || '(no intent)').slice(0, 80)
    lines << "  #{e['id']} [#{e['status']}] #{repo}: #{intent}"
  end
  lines << 'Continue tracking with pst-ledger.rb done|fail; run `pst-ledger.rb list` for full state.'
else
  lines << 'No in-flight ledger tasks at compact time.'
end

puts lines.join("\n")
