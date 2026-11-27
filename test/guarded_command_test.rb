# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"

SCRIPTS = File.expand_path("../scripts", __dir__) unless defined?(SCRIPTS)
require_relative "#{SCRIPTS}/guarded_command"

class GuardedCommandGlobalOptsTest < Minitest::Test
  PUSH_FORMS = [
    "git push",
    "git -C /tmp/repo push origin main",
    "git -C '/tmp/my repo' push",
    "git -c k=v push",
    "git -c core.editor=true -C /x push",
    "git --git-dir=/x/.git push",
    "git --git-dir /x/.git push",
    "git --work-tree=/x push",
    "git --work-tree /x push",
    "git --namespace=ns push",
    "git -P push",
    "git -p push",
    "git --no-pager push",
    "git --paginate push",
    "git --no-replace-objects push",
    "git --bare push",
    "git --exec-path push",
    "git --exec-path=/x push",
    "git --literal-pathspecs push",
    "git --no-optional-locks -C /x push",
    "cd /x && git -C . push",
    "echo hi; git -c a=b push origin HEAD",
    "true | git --no-pager -C /x push"
  ].freeze

  def test_push_detected_in_every_form
    PUSH_FORMS.each { |cmd| assert GuardedCommand.push?(cmd), cmd }
  end

  def test_non_push_commands_are_not_pushes
    [ "git -C /x status", "git -c k=v log push", "git -C push status", "git --bare fetch", "echo git -C x pushy" ].each do |cmd|
      refute GuardedCommand.push?(cmd), cmd
    end
  end

  def test_sibling_matchers_see_through_global_opts
    assert GuardedCommand.invokes?("git -C /x commit -m hi", "git", "commit")
    assert GuardedCommand.merge?("gh pr merge 1")
    assert GuardedCommand.tag_push?("git -C /x push origin v1.0.0")
    assert GuardedCommand.tag_push?("git -c a=b push --tags")
    refute GuardedCommand.tag_push?("git -C /x push")
  end

  def test_force_and_delete_push_through_global_opts
    assert GuardedCommand.force_push?("git -C /x push --force origin main")
    assert GuardedCommand.force_push?("git -c a=b push origin +main")
    assert GuardedCommand.delete_push?("git --no-pager push --delete origin br")
    refute GuardedCommand.force_push?("git -C /x push origin main")
  end

  def test_push_args_exclude_global_opts
    assert_equal [ [ "origin", "main" ] ], GuardedCommand.push_args("git -C /x -c a=b push origin main")
  end

  def test_chained_commands
    assert GuardedCommand.push?("git add . && git -C /x commit -m m && git -C /x push")
    assert_equal [ [ "origin" ], [ "-f" ] ], GuardedCommand.push_args("git -C a push origin; git -C b push -f")
  end

  def test_quoted_text_is_not_a_push
    refute GuardedCommand.push?("echo 'git -C x push'")
  end

  def test_git_chdirs
    assert_equal [ "/a" ], GuardedCommand.git_chdirs("git -C /a push")
    assert_equal [ "/a", "/b" ], GuardedCommand.git_chdirs("git -C /a status && git -c x=y -C /b push")
    assert_empty GuardedCommand.git_chdirs("git push")
  end

  def test_push_chdir
    assert_equal "/a", GuardedCommand.push_chdir("git -C /a push", "/base")
    assert_equal "/base/rel/b", GuardedCommand.push_chdir("git -C rel -C b push", "/base")
    assert_nil GuardedCommand.push_chdir("git push", "/base")
    assert_nil GuardedCommand.push_chdir("git -C /a status", "/base")
  end

  def test_violation_sees_global_opts_push
    assert_equal "git push", GuardedCommand.new("git -C /x push", "local-only").violation
    assert_equal "a direct push to the trunk", GuardedCommand.new("git -C /x push origin main", "merge-ready").violation
    assert_equal "a direct push to the trunk", GuardedCommand.new("git -c a=b push", "merge-ready", branch: "main").violation
    assert_nil GuardedCommand.new("git -C /x push origin feat", "merge-ready").violation
  end
end
