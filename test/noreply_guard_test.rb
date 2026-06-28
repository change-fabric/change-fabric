# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/noreply_guard"

NOREPLY_EMAIL = "1963845+pstaylor-patrick@users.noreply.github.com"
REAL_EMAIL = "patrick@pstaylor.net"
GITHUB_URL = "https://github.com/pstaylor-patrick/synology.git"

class NoreplyCheckTest < Minitest::Test
  def offending(command:, remote_url:, author_emails:)
    NoreplyCheck.new(command:, remote_url:, author_emails:).offending_email
  end

  def test_flags_a_real_email_on_a_github_push
    assert_equal REAL_EMAIL,
                 offending(command: "git push -u origin main", remote_url: GITHUB_URL, author_emails: [ REAL_EMAIL ])
  end

  def test_allows_a_noreply_email_on_a_github_push
    assert_nil offending(command: "git push origin main", remote_url: GITHUB_URL, author_emails: [ NOREPLY_EMAIL ])
  end

  def test_ignores_non_github_remotes
    nas = "http://100.78.26.69:3000/ctx/store.git"
    assert_nil offending(command: "git push origin main", remote_url: nas, author_emails: [ REAL_EMAIL ])
  end

  def test_ignores_non_push_commands
    assert_nil offending(command: "git fetch origin", remote_url: GITHUB_URL, author_emails: [ REAL_EMAIL ])
  end

  def test_flags_when_any_pending_commit_is_non_noreply
    assert_equal REAL_EMAIL,
                 offending(command: "git push", remote_url: GITHUB_URL, author_emails: [ NOREPLY_EMAIL, REAL_EMAIL ])
  end
end

class NoreplyGuardTest < Minitest::Test
  # Fake git facts so the hook is tested without a real repo.
  class FakeGit
    def initialize(remote_url:, emails:)
      @remote_url = remote_url
      @emails = emails
    end

    def remote_url(_remote) = @remote_url
    def author_emails = @emails
  end

  def event(command)
    { "tool_name" => "Bash", "tool_input" => { "command" => command } }
  end

  def emit(event, git)
    io = StringIO.new
    NoreplyGuard.new(event, git: git).emit(io)
    io.string
  end

  def test_denies_a_github_push_with_a_real_email
    git = FakeGit.new(remote_url: GITHUB_URL, emails: [ REAL_EMAIL ])
    decision = JSON.parse(emit(event("git push -u origin main"), git))
    assert_equal "deny", decision.dig("hookSpecificOutput", "permissionDecision")
    assert_includes decision.dig("hookSpecificOutput", "permissionDecisionReason"), REAL_EMAIL
  end

  def test_allows_a_github_push_with_noreply
    git = FakeGit.new(remote_url: GITHUB_URL, emails: [ NOREPLY_EMAIL ])
    assert_empty emit(event("git push origin main"), git)
  end

  def test_allows_a_non_bash_event
    git = FakeGit.new(remote_url: GITHUB_URL, emails: [ REAL_EMAIL ])
    assert_empty emit({ "tool_name" => "Edit" }, git)
  end

  def test_fails_open_on_a_malformed_event
    assert_empty emit({}, FakeGit.new(remote_url: "", emails: []))
  end
end
