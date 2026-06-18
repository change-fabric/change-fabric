#!/usr/bin/env ruby
# frozen_string_literal: true
# PST SessionEnd hook: remove this session's armed marker so the guards go inert.
require_relative 'pst_common'

sid = Pst.session_id
unless sid.empty?
  FileUtils.rm_f(File.join(Pst::HOME, 'armed', sid))
  FileUtils.rm_f(File.join(Pst::HOME, 'reminder-turns', sid))
end
