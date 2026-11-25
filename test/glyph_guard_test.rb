# frozen_string_literal: true

require_relative "test_helpers"
require "open3"
require_relative "#{SKILL_SCRIPTS}/glyph_guard"

class GlyphGuardTest < Minitest::Test
  EM = "—"
  BULLET = "•"
  ELLIPSIS = "…"
  CURLY = "“"

  def run_guard(event)
    io = StringIO.new
    GlyphGuard.new(event).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).fetch("hookSpecificOutput")
  end

  def bash(command) = run_guard("tool_name" => "Bash", "tool_input" => { "command" => command })
  def file(tool, key, text, path: "docs/a.md") = run_guard("tool_name" => tool, "tool_input" => { "file_path" => path, key => text })

  def assert_denied(out, rule)
    assert_equal "deny", out["permissionDecision"]
    assert_includes out["permissionDecisionReason"], "glyph_guard/#{rule}"
  end

  def test_denies_each_glyph_in_a_commit_message
    [ EM, BULLET, ELLIPSIS, CURLY ].each do |glyph|
      assert_denied bash("git commit -m 'Fix a #{glyph} b'"), "glyph"
    end
  end

  def test_denies_a_glyph_in_a_heredoc_commit_message
    assert_denied bash("git commit -m \"$(cat <<'EOF'\nFix #{EM} thing\nEOF\n)\""), "glyph"
  end

  def test_allows_a_clean_commit_and_en_dash
    assert_nil bash("git commit -m 'Fix a - b 1–2'")
  end

  def test_denies_a_glyph_in_a_pr_title_and_body
    assert_denied bash("gh pr create --title 'A #{EM} b' --body ok"), "glyph"
    assert_denied bash("gh pr edit 3 --body 'one #{BULLET} two'"), "glyph"
  end

  def test_denies_a_title_over_sixty
    assert_denied bash("gh pr create --title '#{'a' * 61}' --body ok"), "title_len"
    assert_denied bash("gh pr edit 3 --title='#{'a' * 61}'"), "title_len"
    assert_nil bash("gh pr create --title '#{'a' * 60}' --body ok")
  end

  def test_advises_on_a_long_body_without_denying
    out = bash("gh pr create --title ok --body '#{'b' * 641}'")
    assert_nil out["permissionDecision"]
    assert_includes out["additionalContext"], "glyph_guard/body_len"
    assert_nil bash("gh pr create --title ok --body '#{'b' * 640}'")
  end

  def test_measures_a_heredoc_body
    long = "gh pr create --title ok --body \"$(cat <<'EOF'\n#{'c' * 700}\nEOF\n)\""
    assert_includes bash(long)["additionalContext"], "700 characters"
    assert_nil bash("gh pr create --title ok --body \"$(cat <<'EOF'\nshort\nEOF\n)\"")
  end

  def test_ignores_other_commands_that_mention_glyphs
    assert_nil bash("echo '#{EM}' && git status")
    assert_nil bash("gh pr view 3")
  end

  def test_denies_glyphs_in_markdown_writes_and_edits_only
    assert_denied file("Write", "content", "a #{EM} b"), "glyph"
    assert_denied file("Edit", "new_string", "a #{ELLIPSIS}"), "glyph"
    assert_nil file("Write", "content", "a #{EM} b", path: "lib/a.rb")
    assert_nil file("Write", "content", "plain - text")
  end

  def test_env_waiver_skips_the_glyph_rule_only
    ENV["CF_ALLOW_GLYPH"] = "1"
    assert_nil bash("git commit -m 'a #{EM} b'")
    assert_nil file("Write", "content", "a #{EM} b")
    assert_denied bash("gh pr create --title '#{'a' * 61}'"), "title_len"
  ensure
    ENV.delete("CF_ALLOW_GLYPH")
  end

  def test_fails_open_on_a_malformed_event
    assert_nil run_guard({})
    assert_nil run_guard("tool_name" => "Bash", "tool_input" => "x")
  end

  def test_the_pr_body_dash_fixture_denies_through_the_script
    fixture = File.expand_path("fixtures/glyph_guard/pr_body_dash.json", __dir__)
    out, status = Open3.capture2(RbConfig.ruby, File.expand_path("../scripts/glyph_guard.rb", __dir__), stdin_data: File.read(fixture))
    assert status.success?
    assert_equal "deny", JSON.parse(out).dig("hookSpecificOutput", "permissionDecision")
  end

  def test_the_rule_ids_are_declared
    %w[glyph title_len body_len].each { |rule| assert HookEvent.rule_ids.key?("glyph_guard/#{rule}"), rule }
  end
end
