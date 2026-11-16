# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "git_fixture"
require_relative "../scripts/simplicity_signals"

# Each case under test/fixtures/simplicity/ruby holds a base/ and a head/ tree.
# The test commits base, then head, into a throwaway repo and reads the range,
# so no fixture carries a committed .git directory.
class SimplicitySignalsTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/simplicity/ruby", __dir__)

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) }
  end

  def repo_for(name)
    dir = Dir.mktmpdir
    @dirs << dir
    GitFixture.git_init(dir, "-b", "main")
    GitFixture.git(dir, "config", "user.email", "fixture@example.com")
    GitFixture.git(dir, "config", "user.name", "Fixture")
    %w[base head].each do |side|
      Dir.children(dir).reject { |entry| entry == ".git" }.each { |entry| FileUtils.rm_rf(File.join(dir, entry)) }
      FileUtils.cp_r("#{FIXTURES}/#{name}/#{side}/.", dir)
      GitFixture.git(dir, "add", "-A")
      GitFixture.git(dir, "commit", "-q", "-m", side)
    end
    dir
  end

  def signals(name)
    SimplicitySignals.run(repo: repo_for(name), base: "HEAD~1", head: "HEAD")
  end

  # A two-commit repo from inline file maps; a nil value deletes the file.
  def inline_repo(base, head)
    dir = Dir.mktmpdir
    @dirs << dir
    GitFixture.git_init(dir, "-b", "main")
    GitFixture.git(dir, "config", "user.email", "fixture@example.com")
    GitFixture.git(dir, "config", "user.name", "Fixture")
    [ base, head ].each_with_index do |files, i|
      files.each do |path, body|
        full = File.join(dir, path)
        next FileUtils.rm_f(full) if body.nil?

        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      GitFixture.git(dir, "add", "-A")
      GitFixture.git(dir, "commit", "-q", "--allow-empty", "-m", "c#{i}")
    end
    SimplicitySignals.run(repo: dir, base: "HEAD~1", head: "HEAD")
  end

  def test_same_named_subclasses_in_two_namespaces_are_two_implementations
    report = inline_repo({ "README" => "x\n" }, {
      "lib/notifier_base.rb" => "class NotifierBase\n  def call = raise(NotImplementedError)\nend\n",
      "lib/a.rb" => "module A\n  class Worker < NotifierBase; end\nend\n",
      "lib/b.rb" => "module B\n  class Worker < NotifierBase; end\nend\n"
    })

    refute(report["single_impl"].any? { |entry| entry["base"] == "NotifierBase" })
  end

  def test_same_named_bases_in_two_namespaces_keep_their_own_subclasses
    report = inline_repo({ "README" => "x\n" }, {
      "lib/a.rb" => "module A\n  class NotifierBase; end\nend\n",
      "lib/b.rb" => "module B\n  class NotifierBase; end\nend\n",
      "lib/worker.rb" => "class Worker < A::NotifierBase; end\n"
    })

    assert_includes report["single_impl"], { "base" => "A::NotifierBase", "impls" => [ "Worker" ] }
    refute(report["single_impl"].any? { |entry| entry["base"] == "B::NotifierBase" })
  end

  # Ruby resolves the superclass of a compact `class A::Worker < NotifierBase`
  # at the top level, not inside A.
  def test_a_compact_declaration_resolves_its_superclass_where_declared
    report = inline_repo({ "README" => "x\n" }, {
      "lib/bases.rb" => "class NotifierBase; end\nmodule A\n  class NotifierBase; end\nend\n",
      "lib/worker.rb" => "class A::Worker < NotifierBase; end\n"
    })

    assert_includes report["single_impl"], { "base" => "NotifierBase", "impls" => [ "A::Worker" ] }
    refute(report["single_impl"].any? { |entry| entry["base"] == "A::NotifierBase" })
  end

  def test_a_mixin_used_through_another_module_counts_every_consumer
    report = inline_repo({ "README" => "x\n" }, {
      "lib/mixins.rb" => "module Auditable; end\nmodule Shared\n  include Auditable\nend\n",
      "lib/app.rb" => "class App\n  include Auditable\nend\nclass Other\n  include Shared\nend\n"
    })

    refute(report["single_impl"].any? { |entry| entry["base"] == "Auditable" })
  end

  def test_a_namespace_reopened_across_files_counts_once
    report = inline_repo({ "README" => "x\n" }, {
      "lib/a.rb" => "module Shared\n  class A; end\nend\n",
      "lib/b.rb" => "module Shared\n  class B; end\nend\n"
    })

    assert_in_delta 50.0, report["new_types_per_100"]
  end

  def test_an_include_in_a_nested_class_belongs_only_to_it
    report = inline_repo({ "README" => "x\n" }, {
      "lib/outer.rb" => "module Auditable; end\nclass Outer\n  class Inner\n    include Auditable\n  end\nend\n"
    })

    assert_includes report["single_impl"], { "base" => "Auditable", "impls" => [ "Outer::Inner" ] }
  end

  def test_a_renamed_file_introduces_no_types
    body = "class Foo\n  def a = 1\n  def b = 2\n  def c = 3\nend\n"
    report = inline_repo({ "lib/old.rb" => body }, { "lib/old.rb" => nil, "lib/new.rb" => "# moved\n#{body}" })

    assert_in_delta 0.0, report["new_types_per_100"]
  end

  def test_factory_with_one_product_reports_single_implementation
    report = signals("factory")

    assert_includes report["single_impl"], { "base" => "NotifierBase", "impls" => [ "EmailNotifier" ] }
    assert_equal [ "lib/notifier_factory.rb" ], report["new_files"]
    assert_operator report["new_types_per_100"], :>, 0
  end

  def test_module_included_once_reports_single_implementation
    assert_includes signals("mixin")["single_impl"], { "base" => "Auditable", "impls" => [ "App" ] }
  end

  def test_unused_helper_and_constant_are_reported_but_allowlisted_names_are_not
    names = signals("unused_helper")["unused_ruby"].map { |hit| [ hit["name"], hit["file"], hit["line"] ] }

    assert_includes names, [ "build_legacy", "lib/app.rb", 8 ]
    assert_includes names, [ "LEGACY_LIMIT", "lib/app.rb", 2 ]
    refute(names.any? { |name, _, _| name == "call" })
  end

  def test_added_gem_and_lockfile_growth
    deps = signals("added_gem")["deps"]

    assert_equal [ "httparty" ], deps["gemfile_added"]
    assert_equal [], deps["package_added"]
    assert_equal 3, deps["lockfile_delta"]
  end

  def test_plain_change_yields_empty_signals
    report = signals("plain")

    assert_equal({ "added" => 1, "removed" => 1 }, report["lines"])
    assert_empty report["new_files"]
    assert_in_delta 0.0, report["new_types_per_100"]
    assert_empty report["unused_ruby"]
    assert_empty report["single_impl"]
    assert_equal({ "gemfile_added" => [], "package_added" => [], "lockfile_delta" => 0 }, report["deps"])
    assert_nil report["unused_ts"]
    assert_equal [ SimplicitySignals::DYNAMIC_NOTE ], report["notes"]
  end

  def test_failing_signal_nulls_its_field_and_adds_a_note
    dir = repo_for("plain")
    File.write(File.join(dir, "package.json"), "{ not json")
    GitFixture.git(dir, "add", "-A")
    GitFixture.git(dir, "commit", "-q", "-m", "broken")
    report = SimplicitySignals.run(repo: dir, base: "HEAD~1", head: "HEAD")

    assert_nil report["deps"]
    assert(report["notes"].any? { |note| note.start_with?("deps unavailable") })
    refute_nil report["lines"]
  end

  def test_cli_emits_json_and_exits_zero
    dir = repo_for("plain")
    out = StringIO.new
    status = SimplicitySignals::CLI.run([ "signals", "--repo", dir, "--base", "HEAD~1" ], out:, err: StringIO.new)

    assert_equal 0, status
    assert_kind_of Hash, JSON.parse(out.string)
  end

  def test_cli_usage_errors_exit_two
    err = StringIO.new

    assert_equal 2, SimplicitySignals::CLI.run([ "nope" ], out: StringIO.new, err:)
    assert_equal 2, SimplicitySignals::CLI.run([ "signals", "--bogus", "x" ], out: StringIO.new, err:)
    assert_equal 2, SimplicitySignals::CLI.run([ "signals", "--repo", Dir.mktmpdir.tap { |d| @dirs << d }, "--base", "nope" ], out: StringIO.new, err:)
  end
end
