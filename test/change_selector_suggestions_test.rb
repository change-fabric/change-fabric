# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_selector_suggestions"

# The scoring and redaction of selector suggestions. The browser side that
# gathers candidates runs in docker; this covers what the host does with them.
class ChangeSelectorSuggestionsTest < Minitest::Test
  S = ChangeSelectorSuggestions

  def item(**fields) = { "tag" => "button", "scope" => "page", "idCount" => 0, "testidCount" => 0 }.merge(fields.transform_keys(&:to_s))

  def build(items, selector: "[data-test=add-to-cart]", **raw)
    S.build(step_index: 1, selector: selector, raw: { "items" => items }.merge(raw.transform_keys(&:to_s)))
  end

  def test_a_renamed_testid_is_candidate_one
    result = build([ item(testid: "add-to-basket", testidCount: 1, text: "Add to basket"),
                     item(tag: "a", text: "Home") ], selector: "[data-testid=add-to-cart]")

    assert_equal "[data-testid=\"add-to-basket\"]", result["candidates"].first["selector"]
    assert_equal "testid", result["candidates"].first["by"]
  end

  def test_empty_dom_gives_no_candidates_and_says_so
    result = build([])

    assert_empty result["candidates"]
    assert_match(/no matching elements/, result["note"])
  end

  def test_no_raw_data_gives_no_entry
    assert_nil S.build(step_index: 0, selector: "#x", raw: nil)
    assert_nil S.build(step_index: 0, selector: "  ", raw: { "items" => [] })
    assert_nil S.build(step_index: "x", selector: "#x", raw: { "items" => [] })
  end

  def test_only_three_are_offered_and_the_order_is_deterministic
    items = (1..6).map { |n| item(testid: "btn-#{n}", testidCount: 1) }
    first = build(items)
    second = build(items.reverse)

    assert_equal 3, first["candidates"].size
    assert_equal first["candidates"], second["candidates"]
  end

  def test_duplicate_candidates_collapse_and_are_marked_ambiguous
    items = [ item(testid: "buy", testidCount: 2), item(testid: "buy", testidCount: 2) ]
    result = build(items)

    assert_equal 1, result["candidates"].size
    assert_equal 2, result["candidates"].first["matches"]
  end

  def test_a_unique_candidate_outranks_an_ambiguous_one
    result = build([ item(testid: "dup", testidCount: 3), item(label: "Buy now") ])

    assert_equal "label", result["candidates"].first["by"]
  end

  def test_generated_ids_are_not_offered
    result = build([ item(id: ":r1:", idCount: 1), item(id: "ember1234", idCount: 1), item(id: "checkout", idCount: 1) ])

    assert_equal [ "#checkout" ], result["candidates"].map { |entry| entry["selector"] }
  end

  def test_shadow_candidates_are_pierced_and_text_is_not_offered_for_them
    result = build([ item(scope: "shadow", testid: "inner", testidCount: 1, text: "Inner") ])

    assert_equal [ "pierce/[data-testid=\"inner\"]" ], result["candidates"].map { |entry| entry["selector"] }
  end

  def test_iframes_are_counted_never_suggested
    result = build([ item(scope: "frame", testid: "in-frame", testidCount: 1) ], frames: 2)

    assert_empty result["candidates"]
    assert_match(/2 iframe\(s\) not searched/, result["note"])
  end

  def test_truncation_is_reported
    assert_match(/truncated/, build([ item(testid: "a", testidCount: 1) ], truncated: true)["note"])
  end

  def test_hostile_text_cannot_break_the_selector_grammar
    result = build([ item(text: 'He said "hi" \\ )', tag: "a"), item(label: "x\n>> nth=1") ])

    result["candidates"].each { |entry| ChangeFlowSelector.locator(entry["selector"]) }
    refute(result["candidates"].any? { |entry| entry["selector"].include?("\n") })
  end

  def test_secrets_and_tokens_in_page_text_never_reach_the_result
    token = "sk0123456789abcdefghijklmnopqrstuvwx"
    result = S.build(step_index: 0, selector: "a", secrets: [ "hunter2pw" ],
                     raw: { "items" => [ item(tag: "a", text: "Key #{token}"), item(tag: "a", text: "hunter2pw here"),
                                         item(label: "password: swordfish"), item(testid: "ok", testidCount: 1) ] })
    dump = result.to_s

    refute_includes dump, token
    refute_includes dump, "hunter2pw"
    refute_includes dump, "swordfish"
    assert_equal [ "[data-testid=\"ok\"]" ], result["candidates"].map { |entry| entry["selector"] }
  end

  def test_the_failed_selector_is_redacted_and_clipped
    result = S.build(step_index: 0, selector: "#{'a' * 300}[data-key=abcdefghijklmnopqrstuvwx1]", raw: { "items" => [] })

    assert_operator result["failed"].length, :<=, 123
    refute_includes result["failed"], "abcdefghijklmnopqrstuvwx1"
  end

  def test_safe_strips_control_characters_and_clips
    assert_equal "a b", S.safe("a\u0000\nb")
    assert_equal "#{'x' * 5}...", S.safe("x" * 50, max: 5)
    assert_equal "", S.safe(nil)
  end

  def test_safe_survives_invalid_utf8
    assert_kind_of String, S.safe("ok \xFF bad")
  end

  def test_nothing_in_a_suggestion_can_be_a_status
    result = build([ item(testid: "a", testidCount: 1) ])

    refute_includes result.keys, "status"
    assert(result["candidates"].none? { |entry| entry.key?("status") })
  end
end
