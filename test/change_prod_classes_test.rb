# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "stringio"
require_relative "git_fixture"
require_relative "../scripts/change_apps"
require_relative "../scripts/change_prod_classes"

class ChangeProdClassesTest < Minitest::Test
  Classes = ChangeProdClasses
  FIXTURE = File.expand_path("fixtures/prod/runner.yml", __dir__)

  def config(classes = {}, doors: nil)
    base = YAML.safe_load_file(FIXTURE)
    op = base["change_config"]["operations"]["rotate_tenant_key"]
    classes.each { |name, klass| base["change_config"]["operations"][name] = Marshal.load(Marshal.dump(op)).merge("class" => klass) }
    base["change_policy"]["one_way_doors"] = doors if doors
    base
  end

  def all_classes
    Classes::CLASSES.to_h { |klass| [ "op_#{klass}", klass ] }
  end

  def test_every_class_needs_approval_and_unknown_is_refused
    Classes::CLASSES.each { |klass| assert Classes.approval_required?(klass) }
    assert_raises(ChangeProdEnvelope::Invalid) { Classes.approval_required?("infra") }
  end

  def test_report_lists_ops_by_class_with_the_approval_line
    lines = Classes.report(config(all_classes))
    assert_includes lines, "prod: contracts_and_auth: rotate_tenant_key, op_contracts_and_auth"
    assert_includes lines, "prod: routine: op_routine"
    assert_includes lines, "prod: every class needs passkey and TOTP approval"
    assert_empty lines.grep(/\Aerror:/)
  end

  def test_missing_and_unknown_class_are_errors
    cfg = config({ "no_class" => nil, "odd" => "infra" })
    cfg["change_config"]["operations"]["no_class"].delete("class")
    errors = Classes.errors(cfg)
    assert(errors.any? { |e| e.include?("op no_class has no class") })
    assert(errors.any? { |e| e.include?('unknown class "infra"') })
    assert_equal 2, Classes.report(cfg).grep(/\Aerror:/).length
  end

  def test_notify_text_is_per_class_and_money_warns_backups_do_not_undo
    cfg = config({ "pay" => "money_and_sends" })
    text = Classes.notify_text({ "op" => "pay", "environment" => "production" }, cfg)
    assert_includes text, "pay on production is class money_and_sends"
    assert_includes text, "does not undo external effects"
    assert_includes text, "Needs passkey and TOTP"
    assert_includes Classes.notify_text({ "op" => "rotate_tenant_key", "environment" => "staging" }, cfg), "contracts_and_auth"
    assert_nil Classes.notify_text({ "op" => "ghost", "environment" => "staging" }, cfg)
  end

  def test_notify_text_differs_for_each_class
    cfg = config(all_classes)
    texts = Classes::CLASSES.map { |klass| Classes.notify_text({ "op" => "op_#{klass}", "environment" => "staging" }, cfg) }
    assert_equal texts.length, texts.uniq.length
  end

  def test_no_doors_is_a_noop_with_a_doctor_note
    cfg = config(all_classes)
    assert_nil Classes.linkage(cfg, [ "db/migrate/1.rb" ])
    assert_includes Classes.report(cfg, changed: [ "db/migrate/1.rb" ]),
                    "prod: change_policy.one_way_doors is not declared; op classes are not linked to PR paths"
  end

  def test_linkage_reports_changed_paths_against_ops_of_that_class
    doors = { "contracts_and_auth" => { "paths" => [ "app/auth/**", "config/oauth*.yml" ] },
              "destructive_data" => { "paths" => [ "db/migrate/**" ] } }
    cfg = config({ "drop_col" => "destructive_data", "tidy" => "routine" }, doors: doors)
    hits = Classes.linkage(cfg, [ "app/auth/deep/login.rb", "config/oauth_google.yml", "README.md", "db/migrate/9.rb" ])
    assert_equal [ [ "rotate_tenant_key", "contracts_and_auth", [ "app/auth/deep/login.rb", "config/oauth_google.yml" ] ],
                  [ "drop_col", "destructive_data", [ "db/migrate/9.rb" ] ] ],
                 hits.map { |hit| [ hit[:op], hit[:class], hit[:files] ] }
    assert_empty Classes.linkage(cfg, [ "README.md" ])
    lines = Classes.report(cfg, changed: [ "db/migrate/9.rb" ])
    assert_includes lines, "prod: changed db/migrate/9.rb touches the destructive_data door of op drop_col"
  end

  def test_trailing_globstar_keeps_a_wildcard_prefix
    cfg = config({}, doors: { "contracts_and_auth" => { "paths" => [ "services/*/db/**" ] } })
    hits = Classes.linkage(cfg, [ "services/api/db/migrate/1.rb", "services/api/app/x.rb" ])
    assert_equal [ [ "services/api/db/migrate/1.rb" ] ], hits.map { |hit| hit[:files] }
  end

  def test_routine_never_links_even_when_a_path_matches
    cfg = config({ "tidy" => "routine" }, doors: { "routine" => { "paths" => [ "**" ] } })
    assert_empty Classes.linkage(cfg, [ "a.rb" ])
  end

  def test_class_without_paths_links_nothing
    cfg = config({}, doors: { "contracts_and_auth" => { "content" => [ "secret" ] } })
    assert_empty Classes.linkage(cfg, [ "app/auth/x.rb" ])
  end

  def test_report_is_silent_without_operations
    assert_empty Classes.report({ "change_config" => {} })
    assert_empty Classes.report(nil)
  end

  def test_doctor_wires_the_class_report
    Dir.mktmpdir do |dir|
      path = File.join(dir, "CHANGE.md")
      cfg = config(all_classes)
      cfg["project"] = "demo"
      cfg["change_config"]["lanes"] = { "k6" => { "enabled" => true } }
      File.write(path, "---\n#{YAML.dump(cfg).delete_prefix("---\n")}---\n# Change\n")
      summary = ChangeAppRegistry.doctor(path)
      assert_includes summary, "prod: routine: op_routine"
      assert_includes summary, "one_way_doors is not declared"
    end
  end

  def test_cli_report_diffs_git_and_exits_nonzero_on_a_class_error
    Dir.mktmpdir do |dir|
      GitFixture.git_init(dir, "-b", "main")
      git = ->(*args) { GitFixture.git(dir, "-c", "user.name=t", "-c", "user.email=t@example.com", *args) }
      git.call("commit", "-q", "--allow-empty", "-m", "base")
      FileUtils.mkdir_p(File.join(dir, "db/migrate"))
      File.write(File.join(dir, "db/migrate/1.rb"), "x")
      git.call("add", ".")
      git.call("commit", "-q", "-m", "head")
      cfg = config({ "drop_col" => "destructive_data" }, doors: { "destructive_data" => { "paths" => [ "db/migrate/**" ] } })
      file = File.join(dir, "cfg.yml")
      File.write(file, YAML.dump(cfg))
      out = StringIO.new
      err = StringIO.new
      assert_equal 0, Classes.run([ "report", "--config", file, "--repo", dir, "--base", "HEAD~1", "--head", "HEAD" ], stdout: out, stderr: err), err.string
      assert_includes out.string, "touches the destructive_data door of op drop_col"
      cfg["change_config"]["operations"]["drop_col"].delete("class")
      File.write(file, YAML.dump(cfg))
      assert_equal 1, Classes.run([ "report", "--config", file ], stdout: StringIO.new, stderr: StringIO.new)
      assert_equal 2, Classes.run([ "bogus" ], stdout: StringIO.new, stderr: StringIO.new)
    end
  end
end
