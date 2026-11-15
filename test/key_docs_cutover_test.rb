# frozen_string_literal: true

require "minitest/autorun"

# The per-project key store is the only key source. No shipped doc or script
# may point at the deleted pointer-file enroller or describe env vars and
# secrets.yml as a place keys come from.
class KeyDocsCutoverTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PAID_DOCS = %w[skills/image/SKILL.md skills/roast/SKILL.md skills/narrate/SKILL.md skills/music/SKILL.md
                 skills/b-roll/SKILL.md skills/prototype/SKILL.md skills/walkthrough/SKILL.md
                 skills/walkthrough/reference/release-check.md skills/walkthrough/reference/key-enrollment.md].freeze
  DOC = File.join(ROOT, "skills/walkthrough/reference/key-enrollment.md")

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
end
