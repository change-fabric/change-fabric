# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"

require_relative "../scripts/glyph_guard"

class GlyphGuardTest < Minitest::Test
  EM = "—"      # em dash
  BULLET = "•"  # bullet
  ELLIPSIS = "…"
  RSQUO = "’"   # right smart quote / apostrophe
  EN = "–"      # en dash, allowed

  def setup
    @prev = ENV.delete("CF_ALLOW_GLYPH")
  end

  def teardown
    ENV["CF_ALLOW_GLYPH"] = @prev if @prev
  end

  def guard(tool_name, tool_input)
    io = StringIO.new
    GlyphGuard.new("tool_name" => tool_name, "tool_input" => tool_input).emit(io)
    return nil if io.string.empty?

    JSON.parse(io.string)["hookSpecificOutput"]
  end

  def decision(tool_name, tool_input)
    guard(tool_name, tool_input)&.dig("permissionDecision")
  end

  def test_denies_em_dash_in_git_commit
    assert_equal "deny", decision("Bash", "command" => "git commit -m 'fix#{EM}done'")
  end

  def test_denies_bullet_in_write_content
    assert_equal "deny", decision("Write", "content" => "#{BULLET} item one")
  end

  def test_denies_ellipsis
    assert_equal "deny", decision("Write", "content" => "wait for it#{ELLIPSIS}")
  end

  def test_denies_smart_quote
    assert_equal "deny", decision("Write", "content" => "it#{RSQUO}s done")
  end

  def test_denies_em_dash_in_mcp_jira_comment
    body = { "issueIdOrKey" => "ABC-1", "commentBody" => "looks good#{EM}shipping" }
    assert_equal "deny", decision("mcp__claude_ai_Atlassian__addCommentToJiraIssue", body)
  end

  def test_deny_reason_names_each_offender_and_fix
    reason = guard("Write", "content" => "a#{EM}b#{BULLET}c")["permissionDecisionReason"]
    assert_includes reason, EM
    assert_includes reason, BULLET
    assert_includes reason, "spaced hyphen"
  end

  def test_denies_in_multiedit_added_side
    edits = { "edits" => [ { "old_string" => "x", "new_string" => "y#{EM}z" } ] }
    assert_equal "deny", decision("MultiEdit", edits)
  end

  def test_allows_em_dash_in_edit_old_string_removal
    assert_nil decision("Edit", "old_string" => "before#{EM}after", "new_string" => "before - after")
  end

  def test_allows_en_dash
    assert_nil decision("Write", "content" => "pages 3#{EN}7")
  end

  def test_allows_bash_grep_carrying_the_glyph
    assert_nil decision("Bash", "command" => "grep -n '#{EM}' notes.md")
  end

  def test_allows_read_of_third_party_text
    assert_nil decision("Read", "file_path" => "/x#{EM}y.md")
  end

  def test_allows_read_verb_mcp_tool
    assert_nil decision("mcp__claude_ai_Atlassian__getJiraIssue", "jql" => "summary ~ '#{EM}'")
  end

  def test_allows_clean_input
    assert_nil decision("Write", "content" => "plain - hyphenated text")
  end

  def test_escape_hatch_allows_when_env_set
    ENV["CF_ALLOW_GLYPH"] = "1"
    assert_nil decision("Write", "content" => "title#{EM}body")
  end

  def test_fails_silent_on_malformed_input
    assert_nil decision("Write", "content" => 123)
    assert_nil decision("MultiEdit", "edits" => "not-an-array")
  end

  # Built from fragments so this test file does not itself carry the banned phrase
  # (writing it would otherwise trip the guard the next time it is authored).
  GEN = "Generated with"
  CC = %w[Claude Code].join(" ")
  FOOTER = "#{GEN} [#{CC}](https://claude.com/claude-code)"

  def test_denies_attribution_footer_in_pr_body_file_write
    assert_equal "deny", decision("Write", "content" => "## What\n\nthing\n\n#{FOOTER}")
  end

  def test_denies_attribution_footer_in_git_commit
    assert_equal "deny", decision("Bash", "command" => "git commit -m 'feat: x\n\n#{FOOTER}'")
  end

  def test_denies_plain_footer_without_markdown_link
    assert_equal "deny", decision("Write", "content" => "#{GEN} #{CC}")
  end

  def test_denies_footer_in_mcp_comment
    body = { "issueIdOrKey" => "ABC-1", "commentBody" => "done. #{FOOTER}" }
    assert_equal "deny", decision("mcp__claude_ai_Atlassian__addCommentToJiraIssue", body)
  end

  def test_deny_reason_names_the_footer_fix
    reason = guard("Write", "content" => FOOTER)["permissionDecisionReason"]
    assert_includes reason, "attribution footer"
  end

  def test_escape_hatch_allows_footer_when_env_set
    ENV["CF_ALLOW_GLYPH"] = "1"
    assert_nil decision("Write", "content" => FOOTER)
  end

  def test_allows_unrelated_mention_of_claude_code
    assert_nil decision("Write", "content" => "We run Claude Code in CI.")
  end
end
