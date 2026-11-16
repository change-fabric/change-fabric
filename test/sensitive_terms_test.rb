# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"

require_relative "../scripts/sensitive_terms"

class SensitiveTermsTest < Minitest::Test
  TERMS = [ "acmecorp", "acme corp" ].freeze

  def matched(text) = SensitiveTerms.matched([ text ], TERMS)

  def test_term_inside_a_hash_is_not_a_match
    assert_empty matched("integrity sha512-9fQ2xacmecorpZk7Lw==")
    assert_empty matched("deadbeef0acmecorp1")
  end

  def test_term_as_a_hostname_prefix_still_matches
    assert_equal [ "acmecorp" ], matched("see acmecorpstaging.org for details")
    assert_equal [ "acmecorp" ], matched("deploy to acmecorp-staging now")
    assert_equal [ "acmecorp" ], matched("https://cms.acmecorp.org/admin")
  end

  def test_multi_word_term_still_matches
    assert_equal [ "acme corp" ], matched("Fixed the Acme Corp login bug.")
  end

  def test_match_is_case_insensitive_at_start_of_text
    assert_equal [ "acmecorp" ], matched("ACMECORP rollout")
  end

  def test_term_after_a_literal_escape_still_matches
    assert_equal [ "acmecorp" ], matched('{"note":"Review notes:\\nacmecorp staging"}')
    assert_equal [ "acmecorp" ], matched('printf "a\\tacmecorp"')
  end

  def test_strings_decodes_nested_structures
    history = [ { round: 1, response: { "note" => "Review notes:\nacmecorp staging" } } ]
    assert_equal [ "acmecorp" ], SensitiveTerms.matched(SensitiveTerms.strings(history), TERMS)
  end

  def test_load_ignores_comments_and_blanks
    Dir.mktmpdir do |dir|
      path = File.join(dir, "terms.txt")
      File.write(path, "# comment\n\nacmecorp\n")
      assert_equal [ "acmecorp" ], SensitiveTerms.load(path)
    end
  end

  # The guard path end to end over a real tracked tree: a synthetic term list
  # scanned against `git ls-files` content flags the leaking file only.
  def test_scan_of_git_ls_files_content_flags_only_the_leak
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "clean.txt"), "hash sha1-0acmecorp9 is fine\n")
      File.write(File.join(dir, "leak.md"), "Staging lives at acmecorp-staging.example.org\n")
      git = ->(*args) { Open3.capture2e("git", "-C", dir, *args) }
      git.call("init", "-q")
      git.call("add", ".")
      files = git.call("ls-files").first.split("\n")

      hits = files.select do |file|
        SensitiveTerms.matched([ file, File.read(File.join(dir, file)) ], [ "acmecorp" ]).any?
      end

      assert_equal [ "leak.md" ], hits
    end
  end
end
