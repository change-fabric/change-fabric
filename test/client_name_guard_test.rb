# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"

require_relative "../scripts/client_name_guard"

class ClientNameGuardTest < Minitest::Test
  def setup
    @prev = ENV.delete("CF_ALLOW_SENSITIVE_TERM")
  end

  def teardown
    ENV["CF_ALLOW_SENSITIVE_TERM"] = @prev if @prev
  end

  def with_terms_file(contents)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sensitive_terms.txt")
      File.write(path, contents)
      yield path
    end
  end

  def guard(terms_path, tool_name, tool_input)
    io = StringIO.new
    ClientNameGuard.new({ "tool_name" => tool_name, "tool_input" => tool_input }, terms_path: terms_path).emit(io)
    return nil if io.string.empty?

    JSON.parse(io.string)["hookSpecificOutput"]
  end

  def decision(terms_path, tool_name, tool_input)
    guard(terms_path, tool_name, tool_input)&.dig("permissionDecision")
  end

  def test_denies_flagged_term_in_write_content
    with_terms_file("acme corp\n") do |path|
      assert_equal "deny", decision(path, "Write", "content" => "Fixed the Acme Corp login bug.")
    end
  end

  def test_denies_flagged_term_in_git_commit
    with_terms_file("acme corp\n") do |path|
      assert_equal "deny", decision(path, "Bash", "command" => "git commit -m 'fix acme corp bug'")
    end
  end

  def test_denies_flagged_domain_in_edit
    with_terms_file("acmestaging.org\n") do |path|
      assert_equal "deny", decision(path, "Edit", "old_string" => "x", "new_string" => "https://portal.acmestaging.org/login")
    end
  end

  def test_ignores_comments_and_blank_lines
    with_terms_file("# a comment\n\nacme corp\n") do |path|
      assert_equal "deny", decision(path, "Write", "content" => "acme corp")
    end
  end

  def test_allows_clean_input
    with_terms_file("acme corp\n") do |path|
      assert_nil decision(path, "Write", "content" => "plain generic text")
    end
  end

  def test_allows_edit_old_string_removal
    with_terms_file("acme corp\n") do |path|
      assert_nil decision(path, "Edit", "old_string" => "acme corp", "new_string" => "a prior client")
    end
  end

  def test_no_op_when_terms_file_missing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "does-not-exist.txt")
      assert_nil decision(path, "Write", "content" => "anything at all")
    end
  end

  def test_no_op_when_terms_file_empty
    with_terms_file("") do |path|
      assert_nil decision(path, "Write", "content" => "anything at all")
    end
  end

  def test_escape_hatch_allows_when_env_set
    with_terms_file("acme corp\n") do |path|
      ENV["CF_ALLOW_SENSITIVE_TERM"] = "1"
      assert_nil decision(path, "Write", "content" => "acme corp")
    end
  end

  def test_fails_silent_on_malformed_input
    with_terms_file("acme corp\n") do |path|
      assert_nil decision(path, "Write", "content" => 123)
      assert_nil decision(path, "MultiEdit", "edits" => "not-an-array")
    end
  end

  def test_denies_in_mcp_comment
    with_terms_file("acme corp\n") do |path|
      body = { "issueIdOrKey" => "ABC-1", "commentBody" => "seen on acme corp's staging env" }
      assert_equal "deny", decision(path, "mcp__claude_ai_Atlassian__addCommentToJiraIssue", body)
    end
  end

  def test_allows_read_verb_mcp_tool
    with_terms_file("acme corp\n") do |path|
      assert_nil decision(path, "mcp__claude_ai_Atlassian__getJiraIssue", "jql" => "summary ~ 'acme corp'")
    end
  end
end
