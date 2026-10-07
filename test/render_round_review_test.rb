# frozen_string_literal: true

require_relative "test_helpers"

class RenderRoundReviewTest < Minitest::Test
  BASE = { "title" => "Use a tokenizer", "summary" => "The scan is regex based.", "handoff" => "Rework PR #1." }.freeze

  def build(overrides = {})
    RenderRoundReview.new(BASE.merge(overrides))
  end

  def render(overrides = {})
    build(overrides).render
  end

  def folded(count, tier: "P2", title: "Finding")
    Array.new(count) { |i| { "tier" => tier, "title" => "#{title} #{i}" } }
  end

  def test_renders_header_summary_folded_line_and_fenced_handoff
    body = render("folded" => [ { "tier" => "P2", "title" => "Unanchored BG_NAME" },
                                { "tier" => "P3", "title" => "Dead branch in parse" } ])
    expected = "**Root cause review - Use a tokenizer**\n\nThe scan is regex based.\n\n" \
               "Also found this round: 🟠 P2 Unanchored BG_NAME; 🟢 P3 Dead branch in parse.\n\n" \
               "Agent handoff prompt:\n\n```text\nRework PR #1.\n```"
    assert_equal expected, body
  end

  def test_omits_folded_line_when_folded_is_empty
    expected = "**Root cause review - Use a tokenizer**\n\nThe scan is regex based.\n\n" \
               "Agent handoff prompt:\n\n```text\nRework PR #1.\n```"
    assert_equal expected, render("folded" => [])
  end

  def test_omits_folded_line_when_folded_is_absent
    refute_includes render, RenderRoundReview::FOLDED_LEAD
  end

  def test_uses_the_badge_per_tier_from_render_finding_comment
    %w[P1 P2 P3].each do |tier|
      body = render("folded" => [ { "tier" => tier, "title" => "t" } ])
      assert_includes body, "#{RenderFindingComment::BADGES.fetch(tier)} #{tier} t"
    end
  end

  def test_drops_folded_titles_from_the_end_before_touching_the_summary
    summary = "s" * 500
    review = build("summary" => summary, "folded" => folded(10))
    core = review.core
    assert_operator core.length, :<=, RenderRoundReview::CORE_CAP
    assert_includes core, summary
    assert_includes core, "Finding 0"
    refute_includes core, "Finding 9"
    assert_match(/; \+\d+ more\.\z/, core)
  end

  def test_truncates_summary_once_when_even_zero_folded_titles_fit
    review = build("summary" => "s" * 900, "folded" => folded(3))
    core = review.core
    assert_operator core.length, :<=, RenderRoundReview::CORE_CAP
    assert core.end_with?("...")
    refute_includes core, RenderRoundReview::FOLDED_LEAD
    assert_equal 1, core.scan("...").size
  end

  def test_handoff_is_never_truncated
    handoff = "h" * 3000
    body = render("summary" => "s" * 900, "handoff" => handoff)
    assert body.end_with?("```text\n#{handoff}\n```")
  end

  LOCAL_PATHS = [
    "see ~/x", "see ~", "see $HOME/x", "see ${HOME}/x", "see .claude/plans", "see x/.claude/plans",
    "open file:///x", "open C:\\Users\\x", "open d:\\work\\x", "open C:/Users/x", "open C:/x", "open d:/work/x",
    "open \\\\server\\share\\x", "open \\\\srv.corp\\c$", "open //server/share/x",
    "see /home/x", "see /Users/x", "see /root/plans/x", "read /workspace/change-fabric/plan.md",
    "read /tmp/review/goal.md", "read /var/folders/ab/T/x", "read /private/tmp/x/y",
    "read /opt/build/repo/plan.md", "read `/srv/app/plan.md`", "read (/mnt/c/x)", "read \"/data/x/y\"",
    "cd /repo", "cd /workspace", "cd /tmp", "cd /tmp.", "cd `/repo`", "cd /", "run /cf:plan in /repo",
    "edit scripts\\x.rb", "See [plan](/workspace/x.md)", "see </tmp>", "set path=/repo", "open (C:/x)", "see */tmp*", "see _/repo_", "a | /workspace | b", "use {/tmp}",
    "read \"~/x\"", "see [a](~/x)", "see <C:\\x>", "use key=$HOME/x", "a,/tmp/x", "a;/repo", "'/srv/x'",
    "See path:/tmp/plan.md", "path:/workspace/change-fabric/plan.md", "file:/x", "at:~/x", "env:$HOME/x", "a/b:/tmp/x"
  ].freeze

  PARENT_PATHS = [
    "Read ../private/plan.md", "See ../../tmp/plan.md", "See [plan](../plan.md)",
    "path:../x.md", "Open docs/../../x.md"
  ].freeze

  PORTABLE_TEXT = [
    "Rework PR #1 in owner/repo.", "See https://github.com/owner/repo/pull/1/files",
    "Edit scripts/render_round_review.rb and test/x_test.rb", "Run /cf:plan first",
    "Fold P2/P3 and/or drop them", "Call gh api repos/owner/repo/pulls/1/reviews",
    "Use ./scripts/x.rb", "Ratio 1/2/3 holds",
    "Run /cf:plan, then /cf:drive.", "See (https://example.com/a/b).",
    "See [plan](https://host/x)", "See [doc](docs/x.md)", "Run </cf:plan>", "path=docs/x.md",
    "See <https://host/x?a=b>", "path:docs/x.md", "Note: see docs/x.md"
  ].freeze

  def test_raises_on_handoff_naming_a_local_path
    LOCAL_PATHS.each do |handoff|
      assert_raises(RuntimeError, handoff) { build("handoff" => handoff) }
    end
  end

  def test_raises_on_handoff_naming_a_parent_directory_path
    PARENT_PATHS.each do |handoff|
      assert_raises(RuntimeError, handoff) { build("handoff" => handoff) }
    end
  end

  def test_accepts_portable_handoff_text
    PORTABLE_TEXT.each do |handoff|
      assert build("handoff" => handoff).render.end_with?("#{handoff}\n```"), handoff
    end
  end

  def test_raises_on_handoff_containing_a_code_fence
    assert_raises(RuntimeError) { build("handoff" => "run\n```\nx\n```") }
  end

  def test_raises_on_unknown_folded_tier
    assert_raises(RuntimeError) { build("folded" => [ { "tier" => "P4", "title" => "t" } ]) }
  end

  def test_raises_on_empty_title
    assert_raises(RuntimeError) { build("title" => "  ") }
  end

  def test_render_starts_with_header_prefix
    assert render.start_with?(RenderRoundReview::HEADER_PREFIX)
  end
end
