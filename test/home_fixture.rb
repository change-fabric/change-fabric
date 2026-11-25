# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# HOME isolation for every test process. The cf secret store, the approval
# store and every other ~/.claude path resolve from ENV["HOME"] at call time,
# so a test that forgets its own temp HOME would read and write the real
# one. A LocalStore once rewrote a live approval enrollment that way. Loaded
# before any test file (Rakefile ruby_opts, via git_fixture), this points
# HOME at a throwaway dir for the whole process; tests that set their own
# temp HOME still do, and restore to this one.
module HomeFixture
  REAL_HOME = ENV.fetch("HOME", Dir.home)

  unless defined?(HOME)
    HOME = File.realpath(Dir.mktmpdir("cf-test-home-"))
    # Tools found through the real home keep working without reading it for cf state.
    ENV["RBENV_ROOT"] ||= File.join(REAL_HOME, ".rbenv")
    ENV["DOCKER_CONFIG"] ||= File.join(REAL_HOME, ".docker")
    ENV["HOME"] = HOME
    pid = Process.pid
    at_exit { FileUtils.rm_rf(HOME) if Process.pid == pid }
  end
end
