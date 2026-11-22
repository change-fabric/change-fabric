# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "fileutils"
require_relative "../scripts/change_suite"
require_relative "../scripts/change_case_selection"
require_relative "../scripts/change_run"

# `--changed`: diff-based case selection. One test per selection rule, plus
# the gate-safety refusal and the clipping of echoed values.
class ChangeChangedSelectionTest < Minitest::Test
  ANNOTATED = <<~YAML
    suite: checkout
    suite_version: 6
    cases:
      - id: cart
        acceptance: The cart renders.
        covers: [ "app/cart/**", "lib/cart.rb" ]
        steps:
          - goto: /cart
      - id: pay
        acceptance: Payment works.
        covers: [ "app/pay/*.rb" ]
        steps:
          - goto: /pay
  YAML

  MIXED = <<~YAML
    suite: profile
    suite_version: 6
    cases:
      - id: known
        acceptance: Covered case.
        covers: [ "app/profile/**" ]
        steps:
          - goto: /profile
      - id: legacy
        acceptance: Unannotated case.
        steps:
          - goto: /legacy
  YAML

  def with_repo(files = { "checkout.cf-testcases.yml" => ANNOTATED })
    Dir.mktmpdir do |dir|
      repo = File.realpath(dir)
      git(repo, "init", "-q", "-b", "main")
      files.each { |name, text| File.write(File.join(repo, name), text) }
      git(repo, "add", "-A")
      git(repo, "commit", "-q", "-m", "base")
      git(repo, "checkout", "-q", "-b", "topic")
      yield repo
    end
  end

  def git(repo, *args)
    out, status = Open3.capture2e("git", "-C", repo, "-c", "user.email=t@example.com", "-c", "user.name=t", *args)
    raise out unless status.success?

    out
  end

  def commit_file(repo, path, text = "x")
    FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
    File.write(File.join(repo, path), text)
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "change")
  end

  def pick(repo, strict: false, base: "main")
    set = ChangeSuiteSet.load([ "*.cf-testcases.yml" ], repo)
    paths = ChangeCaseSelection.changed_paths(base, repo)
    ChangeCaseSelection.select(set, paths, repo: repo, strict: strict).cases.map(&:qualified_id)
  end

  def test_a_covers_match_selects_only_that_case
    with_repo do |repo|
      commit_file(repo, "app/cart/view.rb")
      assert_equal [ "checkout/cart" ], pick(repo)
    end
  end

  def test_no_match_selects_nothing
    with_repo do |repo|
      commit_file(repo, "docs/readme.txt")
      assert_empty pick(repo)
    end
  end

  def test_a_single_star_does_not_cross_directories
    with_repo do |repo|
      commit_file(repo, "app/pay/deep/x.rb")
      assert_empty pick(repo)
      commit_file(repo, "app/pay/x.rb")
      assert_equal [ "checkout/pay" ], pick(repo)
    end
  end

  def test_an_unannotated_case_always_runs
    with_repo("mixed.cf-testcases.yml" => MIXED) do |repo|
      commit_file(repo, "docs/readme.txt")
      assert_equal [ "profile/legacy" ], pick(repo)
    end
  end

  def test_a_suite_file_edit_selects_the_whole_suite
    with_repo do |repo|
      commit_file(repo, "checkout.cf-testcases.yml", "#{ANNOTATED}\n# edited\n")
      assert_equal %w[checkout/cart checkout/pay], pick(repo)
    end
  end

  def test_strict_with_one_unannotated_case_runs_everything
    with_repo("mixed.cf-testcases.yml" => MIXED) do |repo|
      commit_file(repo, "docs/readme.txt")
      assert_equal [ "profile/legacy" ], pick(repo)
      assert_equal %w[profile/known profile/legacy], pick(repo, strict: true)
    end
  end

  def test_strict_with_every_case_annotated_still_narrows
    with_repo do |repo|
      commit_file(repo, "app/cart/view.rb")
      assert_equal [ "checkout/cart" ], pick(repo, strict: true)
    end
  end

  def test_a_bad_base_ref_is_an_error_and_is_clipped
    with_repo do |repo|
      error = assert_raises(ChangeCaseSelection::Error) { ChangeCaseSelection.changed_paths("-#{'x' * 500}", repo) }
      assert_operator error.message.length, :<, 200
      assert_raises(ChangeCaseSelection::Error) { ChangeCaseSelection.changed_paths("no-such-ref", repo) }
    end
  end

  def test_clip_strips_control_characters_and_truncates
    assert_equal "a b", ChangeCaseSelection.clip("a\nb")
    assert_equal "#{'z' * 80}...", ChangeCaseSelection.clip("z" * 200)
  end

  def test_summary_caps_the_listed_cases
    with_repo do |repo|
      commit_file(repo, "checkout.cf-testcases.yml", "#{ANNOTATED}\n# edited\n")
      set = ChangeSuiteSet.load([ "*.cf-testcases.yml" ], repo)
      result = ChangeCaseSelection.select(set, ChangeCaseSelection.changed_paths("main", repo), repo: repo)
      lines = ChangeCaseSelection.summary(result, 2, "origin/main\nspoof", cap: 1)
      assert_includes lines.first, "2 of 2"
      refute_includes lines.first, "\n"
      assert_equal 3, lines.size
    end
  end

  def test_covers_must_be_a_non_empty_list_of_relative_globs
    [ [], [ "/abs" ], [ "../up" ], [ "" ], [ 3 ] ].each do |bad|
      assert_raises(ChangeSuite::Error, bad.inspect) { ChangeSuite.covers(bad, "where") }
    end
    assert_nil ChangeSuite.covers(nil, "where")
    assert_equal [ "a/**" ], ChangeSuite.covers("a/**", "where")
  end

  def test_the_covers_key_needs_suite_version_six
    text = ANNOTATED.sub("suite_version: 6", "suite_version: 5")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "s.cf-testcases.yml")
      File.write(path, text)
      error = assert_raises(ChangeSuite::Error) { ChangeSuite.load_file(path) }
      assert_includes error.message, "added in suite_version 6"
    end
  end

  def test_changed_parses_with_and_without_a_ref
    runner = ChangeRun.new(%w[all])
    assert_equal "origin/main", runner.send(:parse_args, %w[testcases --changed]).changed
    assert_equal "HEAD~2", runner.send(:parse_args, %w[testcases --changed HEAD~2 --strict]).changed
    assert runner.send(:parse_args, %w[testcases --changed --strict]).strict
  end

  def test_changed_is_refused_for_the_all_scope_and_other_scopes
    runner = ChangeRun.new(%w[all])
    [ %w[all --changed], %w[k6 --changed], [ "testcases", "--strict" ] ].each do |argv|
      assert_raises(SystemExit, argv.inspect) { capture_io { runner.send(:parse_args, argv) } }
    end
  end

  def test_resolve_changed_reports_none_and_intersects_with_case
    with_repo do |repo|
      lane = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }, repo)
      config = Object.new
      config.define_singleton_method(:lane) { |_name| lane }
      runner = ChangeRun.new(%w[all])
      runner.instance_variable_set(:@repo_root, repo)
      args = runner.send(:parse_args, %w[testcases --changed main])
      runner.instance_variable_set(:@args, args)
      capture_io { assert_equal :none, runner.send(:resolve_changed, config, [ "testcases" ]) }
      commit_file(repo, "app/cart/view.rb")
      capture_io { assert_nil runner.send(:resolve_changed, config, [ "testcases" ]) }
      assert_equal [ "checkout/cart" ], runner.instance_variable_get(:@case_select)
      runner.instance_variable_set(:@args, runner.send(:parse_args, %w[testcases --changed main --case pay]))
      capture_io { assert_equal :none, runner.send(:resolve_changed, config, [ "testcases" ]) }
    end
  end

  def resolver(repo, argv, files_lane = { "suites" => [ "*.cf-testcases.yml" ] })
    lane = ChangeConfig::LaneConfig.new("testcases", files_lane, repo)
    config = Object.new
    config.define_singleton_method(:lane) { |_name| lane }
    runner = ChangeRun.new(%w[all])
    runner.instance_variable_set(:@repo_root, repo)
    runner.instance_variable_set(:@args, runner.send(:parse_args, argv))
    [ runner, config ]
  end

  def test_a_diff_touching_only_an_excluded_suite_is_no_cases_affected
    files = { "checkout.cf-testcases.yml" => ANNOTATED, "other.cf-testcases.yml" => MIXED.sub("suite: profile", "suite: other") }
    with_repo(files) do |repo|
      commit_file(repo, "app/profile/x.rb")
      runner, config = resolver(repo, %w[testcases --changed main --suite checkout])
      capture_io { assert_equal :none, runner.send(:resolve_changed, config, [ "testcases" ]) }
    end
  end

  def test_a_broken_suite_is_left_for_the_lane_to_report
    with_repo do |repo|
      commit_file(repo, "broken.cf-testcases.yml", "suite: broken\ncases: nope\n")
      runner, config = resolver(repo, %w[testcases --changed main])
      capture_io { assert_nil runner.send(:resolve_changed, config, [ "testcases" ]) }
      assert_nil runner.instance_variable_get(:@case_select)
    end
  end
end
