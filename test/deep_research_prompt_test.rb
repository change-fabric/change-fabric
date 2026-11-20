# frozen_string_literal: true

require_relative "deep_research_helper"

class DeepResearchPromptTest < Minitest::Test
  include DeepResearchHelper

  def test_render_has_title_line_skeleton_and_primary_source_rule
    text = DeepResearchPrompt.render(question: "Why?", run_id: "dr-x")
    assert_match(/\ADeep research \[dr-x\]: Why\?/, text)
    %w[Summary Findings Sources Unverified Contested].each { |h| assert_includes text, "## #{h}" }
    assert_includes text, "Prefer primary sources"
  end

  def test_cache_key_ignores_the_run_id_and_is_stable
    args = { question: "Why?", contexts: [], backend: "manual", model: "chatgpt-web" }
    assert_equal DeepResearchPrompt.cache_key(**args), DeepResearchPrompt.cache_key(**args)
    refute_equal DeepResearchPrompt.cache_key(**args), DeepResearchPrompt.cache_key(**args, backend: "api")
    refute_equal DeepResearchPrompt.cache_key(**args), DeepResearchPrompt.cache_key(**args, question: "Other?")
  end

  def test_two_renders_share_a_cache_key_but_not_run_id_or_prompt_sha
    first = cli("prompt", "--question", "Same question", "--slug", "s")
    second = cli("prompt", "--question", "Same question", "--slug", "s")
    runs = DeepResearchStore.all.map(&:last)
    assert_equal [ 6, 6 ], [ first[0], second[0] ]
    assert_equal 2, runs.size
    assert_equal 1, runs.map { |r| r["cache_key"] }.uniq.size
    assert_equal 2, runs.map { |r| r["id"] }.uniq.size
    assert_equal 2, runs.map { |r| r["prompt_sha256"] }.uniq.size
  end

  def test_context_pack_is_fenced_labeled_and_capped
    text = DeepResearchPrompt.render(question: "Q", contexts: [ [ "notes.txt", "hello" ] ])
    assert_includes text, "Context (notes.txt):\n```\nhello\n```"
    big = [ [ "a.txt", "x" * 40_000 ], [ "b.txt", "y" * 30_000 ] ]
    error = assert_raises(DeepResearchPrompt::Error) { DeepResearchPrompt.render(question: "Q", contexts: big) }
    assert_includes error.message, "b.txt"
  end
end
