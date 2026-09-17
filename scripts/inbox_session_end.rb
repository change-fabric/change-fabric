#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hook_event'
require_relative 'inbox_store'
require_relative 'inbox_paths'
require_relative 'inbox_roster'

# SessionEnd hook: commits whatever this session wrote to the resolved inbox
# root, when a project has actually opted into the inbox capability. The
# inbox root is local git history so a lost or duplicated handoff can be
# traced afterwards, not a backup, and never a substitute for the ledger. It
# is silent by design, including on failure.
#
# It self-gates on the resolved root existing and carrying a roster.json, the
# same test inbox_prompt_hook.rb uses, so it does nothing at all for a
# project that never ran `inbox_store.rb init`. Beyond that gate it commits
# regardless of which project the session was in: it only ever touches the
# inbox root, and does nothing when that root is clean, which is the normal
# case for a session that never went near it.
class InboxSessionEnd
  def self.run(_event)
    return unless configured?

    InboxStore.commit(nil)
  rescue StandardError
    nil
  end

  def self.configured?
    root = InboxPaths.root
    File.directory?(root) && File.exist?(InboxRoster.path(root))
  rescue StandardError
    false
  end
end

InboxSessionEnd.run(HookEvent.read) if __FILE__ == $PROGRAM_NAME
