# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/change_pr_facts"

class ChangePrFactsTest < Minitest::Test
  URL = "https://github.com/acme/widgets/pull/7"

  # A stand-in for `gh`: the changed_files count, then the --slurp pages.
  def runner(count:, pages:, calls: [])
    lambda do |*args|
      calls << args
      args.include?("--jq") ? "#{count}\n" : JSON.generate(pages)
    end
  end

  def test_files_returns_every_name_sorted_and_unique_across_pages
    pages = [ [ { "filename" => "b.rb" }, { "filename" => "a.rb" } ], [ { "filename" => "c.rb" } ] ]
    assert_equal %w[a.rb b.rb c.rb], ChangePrFacts.files(URL, runner: runner(count: 3, pages: pages))
  end

  def test_a_rename_returns_both_the_new_and_the_previous_name
    pages = [ [ { "filename" => "docs/new.md", "previous_filename" => "scripts/guard.rb", "status" => "renamed" } ] ]
    assert_equal %w[docs/new.md scripts/guard.rb], ChangePrFacts.files(URL, runner: runner(count: 1, pages: pages))
  end

  def test_the_api_limit_of_3000_files_fails_closed
    error = assert_raises(ChangePrFacts::Unreadable) { ChangePrFacts.files(URL, runner: runner(count: 3000, pages: [ [] ])) }
    assert_match(/3000/, error.message)
    assert_raises(ChangePrFacts::Unreadable) { ChangePrFacts.files(URL, runner: runner(count: 4500, pages: [ [] ])) }
  end

  def test_a_truncated_page_fails_closed
    pages = [ [ { "filename" => "a.rb" } ] ]
    error = assert_raises(ChangePrFacts::Unreadable) { ChangePrFacts.files(URL, runner: runner(count: 150, pages: pages)) }
    assert_match(/truncated/, error.message)
  end

  def test_unreadable_output_and_gh_errors_fail_closed
    assert_raises(ChangePrFacts::Unreadable) { ChangePrFacts.files(URL, runner: ->(*) { "not json" }) }
    assert_raises(ChangePrFacts::Unreadable) { ChangePrFacts.files(URL, runner: ->(*) { raise ChangePrFacts::Unreadable, "gh failed" }) }
    assert_raises(ChangePrFacts::Unreadable) { ChangePrFacts.files("https://example.com/not-a-pr", runner: ->(*) { "[]" }) }
  end

  def test_repo_and_pages_come_from_the_pr_url
    calls = []
    ChangePrFacts.files(URL, runner: runner(count: 1, pages: [ [ { "filename" => "a" } ] ], calls: calls))
    assert(calls.all? { |args| args.any? { |arg| arg.start_with?("repos/acme/widgets/pulls/7") } })
    assert_includes calls.last, "--paginate"
    assert_equal "repo:github.com/acme/widgets", ChangePrFacts.repo_id(URL)
  end

  def test_head_reads_sha_base_and_title_and_refuses_an_incomplete_answer
    ok = ->(*) { JSON.generate("headRefOid" => "a" * 40, "baseRefName" => "main", "title" => "T") }
    assert_equal({ sha: "a" * 40, base: "main", title: "T" }, ChangePrFacts.head(URL, runner: ok))
    assert_raises(ChangePrFacts::Unreadable) { ChangePrFacts.head(URL, runner: ->(*) { JSON.generate("headRefOid" => "", "baseRefName" => "main", "title" => "T") }) }
    assert_raises(ChangePrFacts::Unreadable) { ChangePrFacts.head(URL, runner: ->(*) { "oops" }) }
  end
end
