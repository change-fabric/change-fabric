# frozen_string_literal: true

require "minitest/autorun"

# The per-project key store is the only key source. No shipped doc or script
# may point at the deleted pointer-file enroller or describe env vars and
# secrets.yml as a place keys come from.
class KeyDocsCutoverTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PAID_DOCS = %w[skills/image/SKILL.md skills/roast/SKILL.md skills/narrate/SKILL.md skills/music/SKILL.md
                 skills/b-roll/SKILL.md skills/prototype/SKILL.md skills/walkthrough/SKILL.md
                 skills/walkthrough/reference/release-check.md skills/enroll/reference/key-enrollment.md].freeze
  DOC = File.join(ROOT, "skills/enroll/reference/key-enrollment.md")
  # Built so a plain grep for the old path finds nothing, this file included.
  OLD_DOC = [ "walkthrough", "reference", "key-enrollment" ].join("/")

  def shipped_files
    Dir[File.join(ROOT, "{skills,scripts,hooks}/**/*.{md,rb}")]
  end

  def test_nothing_references_the_deleted_enroller
    offenders = shipped_files.select { |f| File.read(f).include?("cf_secrets_enroll") }
    assert_empty offenders.map { |f| f.delete_prefix("#{ROOT}/") }
  end

  def test_no_doc_names_env_or_pointer_file_as_a_key_source
    pattern = /(from the environment|named by `CF_SECRETS_ENV`|enrolled source|recorded source)/
    offenders = PAID_DOCS.map { |p| File.join(ROOT, p) }.select { |f| File.read(f).match?(pattern) }
    assert_empty offenders.map { |f| f.delete_prefix("#{ROOT}/") }
  end

  def test_enrollment_doc_uses_cf_keys_and_inherit_confirmation
    text = File.read(DOC)
    assert_includes text, "cf_keys.rb enroll"
    assert_includes text, "cf_keys.rb confirm-inherit"
    assert_includes text, "There is no global fallback"
  end

  def test_enrollment_doc_covers_remove_hooks_and_defer
    text = File.read(DOC)
    assert_includes text, "cf_keys.rb remove"
    assert_includes text, "Session start never asks about keys"
    assert_includes text, "UserPromptSubmit"
    assert_includes text, "cf_keys.rb defer"
  end

  # A paid skill hands exit 4 to cf:enroll and re-runs; it never just tells
  # the user to paste a snippet and stop.
  def test_every_paid_skill_hands_exit_4_to_cf_enroll
    paid = Dir[File.join(ROOT, "skills/*/SKILL.md")].select { |f| File.read(f).match?(/\A---\n.*?^providers:/m) }
    refute_empty paid
    missing = paid.reject { |f| File.read(f).include?("cf:enroll") }
    assert_empty missing.map { |f| f.delete_prefix("#{ROOT}/") }
  end

  def test_optional_roast_callers_run_cf_enroll_on_exit_4
    %w[plan resolve-threads brainstorm drive design].each do |name|
      assert_includes File.read(File.join(ROOT, "skills/#{name}/SKILL.md")), "cf:enroll", name
    end
  end

  def test_no_link_to_the_old_walkthrough_copy
    offenders = (shipped_files + [ File.join(ROOT, "README.md") ]).select do |f|
      File.read(f).include?(OLD_DOC)
    end
    assert_empty offenders.map { |f| f.delete_prefix("#{ROOT}/") }
  end

  def test_readme_carries_the_breaking_reenroll_note
    text = File.read(File.join(ROOT, "README.md"))
    assert_includes text, "BREAKING: a paid skill exits 4 after upgrading"
    assert_includes text, "cf_keys.rb enroll"
  end

  def test_imagine_falls_back_on_exit_4_not_a_missing_env_var
    text = File.read(File.join(ROOT, "skills/imagine/SKILL.md"))
    refute_includes text, "`OPENAI_API_KEY` is missing"
    assert_includes text, "exits 4"
  end
end
