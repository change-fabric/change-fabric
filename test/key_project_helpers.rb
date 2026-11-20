# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

# A fake Claude Code scratchpad under a throwaway TMPDIR, so the matcher sees
# <tmp>/claude-<uid>/<project>/<session>/scratchpad without touching the real
# /private/tmp, and a bare git repo to stand in for the enrolled project.
module KeyProjectHelpers
  def make_scratchpad!
    @kp_saved_tmpdir = ENV.fetch("TMPDIR", nil)
    @kp_tmp = File.realpath(Dir.mktmpdir("kp"))
    ENV["TMPDIR"] = @kp_tmp
    @scratchpad = File.join(@kp_tmp, "claude-#{Process.uid}", "-proj", "sess-1", "scratchpad")
    FileUtils.mkdir_p(@scratchpad)
    @scratchpad
  end

  def remove_scratchpad!
    ENV["TMPDIR"] = @kp_saved_tmpdir
    FileUtils.rm_rf(@kp_tmp) if @kp_tmp
  end

  def make_repo!(dir)
    FileUtils.mkdir_p(dir)
    _out, status = Open3.capture2e("git", "init", "-q", dir)
    raise "git init failed" unless status.success?

    File.realpath(dir)
  end
end
