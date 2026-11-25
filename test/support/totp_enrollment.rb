# frozen_string_literal: true

require "fileutils"
require_relative "../home_fixture"
require_relative "../../scripts/approval_console/local_store"
require_relative "../../scripts/approval_console/totp"

# Enrolls a TOTP seed in the test's temp HOME (callers set ENV["HOME"] first)
# and mints codes for it, so approval tests drive the real fenced store.
module TotpEnrollment
  # Enrolls and returns the store; also installs the read guard file the host
  # health check looks for, so the host is healthy.
  def enroll_totp(home = ENV.fetch("HOME"))
    store = ApprovalConsole::LocalStore.new
    store.enroll!(label: "test-host")
    guard = File.join(home, ApprovalConsole::HostHealth::GUARD)
    FileUtils.mkdir_p(File.dirname(guard))
    File.write(guard, "# stub\n")
    store
  end

  def totp_now(store, offset: 0, time: Time.now)
    ApprovalConsole::Totp.code(store.seed, ApprovalConsole::Totp.step_for(time) + offset)
  end
end
