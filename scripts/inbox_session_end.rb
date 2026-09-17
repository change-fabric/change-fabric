#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hook_event'
require_relative 'inbox_store'

# SessionEnd hook: commits whatever the team wrote to the inbox directory
# during this session. The repo has no remote and gets none; this is a local
# history so a lost or duplicated handoff can be traced afterwards, not a
# backup. It is silent by design, including on failure.
#
# It commits regardless of which project the session was in. That is
# deliberate and safe: it only ever touches the inbox directory, and it does
# nothing when that directory is clean, which is the normal case for a session
# that never went near it.
class InboxSessionEnd
  def self.run(_event)
    InboxStore.commit(nil)
  rescue StandardError
    nil
  end
end

InboxSessionEnd.run(HookEvent.read) if __FILE__ == $PROGRAM_NAME
