# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

# cf:enroll's contract as written: the terminal snippet is the default, the
# cf:secret-intake page is the fallback, deferral is 1 or 7 days, and nothing
# asks the user to paste a key into the chat.
class EnrollSkillTest < Minitest::Test
  DIR = File.expand_path("../skills/enroll", __dir__)
  SKILL = File.read(File.join(DIR, "SKILL.md"))
  CODEX = File.read(File.join(DIR, "reference", "codex.md"))

  def front = YAML.safe_load(SKILL[/\A---\n(.*?)\n---\n/m, 1])

  def test_frontmatter_names_the_skill_without_providers
    assert_equal "cf:enroll", front["name"]
    assert_equal "workflow", front["group"]
    refute front.key?("providers"), "cf:enroll itself makes no paid call"
    assert_operator front["description"].length, :<=, 1024
  end

  def test_terminal_snippet_is_the_default_and_project_scope_comes_first
    enroll_now = SKILL[/^1\. Enroll now \(recommended\).*?(?=^2\.)/m]
    assert enroll_now, "the first option is enroll now"
    assert_includes enroll_now, "ruby ~/.claude/cf/bin/cf_keys.rb enroll <provider> --dir <root>"
    assert_includes enroll_now, "Project scope is the default"
    assert_includes enroll_now, "--scope tree"
  end

  def test_upload_page_is_the_fallback
    page = SKILL[/^3\. Use the upload page \(fallback.*?(?=^4\.)/m]
    assert page
    assert_includes page, "cf:secret-intake"
    assert_includes page, "intake --name <ENV_NAME> --validate <provider>"
    assert_includes page, "push <ENV_NAME> --to cf-key:<provider> --dir <root>"
  end

  def test_defer_offers_one_or_seven_days_defaulting_to_seven
    assert_includes SKILL, "cf_keys.rb defer <provider> --dir <root> --days 7"
    assert_includes SKILL, "`--days 1`; 7 is the default"
    assert_includes CODEX, "Defer for 7 days (or say 1 day)"
  end

  def test_after_enrolling_it_verifies_and_reruns_once
    assert_includes SKILL, "wait for the user to say done"
    assert_includes SKILL, "cf_keys.rb status --dir <root>"
    assert_includes SKILL, "re-runs its paid step once"
    assert_includes SKILL, "never loop"
  end

  def test_never_asks_for_a_key_in_chat
    [ SKILL, CODEX ].each do |text|
      assert_match(/Never ask the user to paste a key into the (chat|conversation)/, text)
      refute_match(/paste (your|the) (api )?key (here|below|in(to)? (the )?chat)/i, text)
    end
  end

def test_a_direct_run_never_skips_an_expired_key
  assert_includes SKILL, "never one whose entry says `(expired)`"
end

  def test_plain_question_fallback_and_away_default
    assert_includes SKILL, "plain numbered question"
    assert_includes SKILL, "Away mode: take Defer (7 days)"
    assert_includes CODEX, "$cf-enroll"
  end
end
