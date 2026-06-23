#!/usr/bin/env ruby
# frozen_string_literal: true
# PST SessionEnd hook: disarm session and reap tracked Docker containers (rule 20).
require_relative 'pst_common'

sid = Pst.session_id
unless sid.empty?
  FileUtils.rm_f(File.join(Pst::HOME, 'armed', sid))

  Pst.reap_docker(sid)

  # Rule 22: clear session ledger
  ledger_file = Pst.ledger_path(sid)
  FileUtils.rm_f(ledger_file)
end
