# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/change_delivery"

# The change_delivery.rb CLI: validate-verdict, flags, and conformance against
# the shipped traces (with the reference controller, and with a wrong one).
class ChangeDeliveryTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/delivery", __dir__)
  REFERENCE = File.expand_path("../scripts/change_delivery_reference.rb", __dir__)

  def cli(*argv)
    out = StringIO.new
    err = StringIO.new
    code = ChangeDelivery.run(argv, stdout: out, stderr: err)
    [ code, out.string, err.string ]
  end

  def test_validate_verdict_accepts_and_rejects
    assert_equal 0, cli("validate-verdict", File.join(FIXTURES, "verdict_pass.json")).first
    code, out, = cli("validate-verdict", File.join(FIXTURES, "verdict_stale_pass.json"))
    assert_equal 1, code
    assert_includes out, "older than 180s"
    assert_equal 0, cli("validate-verdict", File.join(FIXTURES, "heartbeat.json")).first
    assert_equal 2, cli("validate-verdict", "/nonexistent.json").first
    assert_equal 2, cli("validate-verdict").first
  end

  def write_change(dir, adapter)
    File.write(File.join(dir, "CHANGE.md"), <<~MD)
      ---
      change_config:
        delivery:
          flags:
            main: #{adapter}
          rollouts:
            new-checkout: { owner: "@m", flag: new_checkout, flags: main, profile: production }
      ---
      body
    MD
    File.join(dir, "CHANGE.md")
  end

  def test_flags_dispatches_to_the_fixture_adapter
    Dir.mktmpdir do |dir|
      config = write_change(dir, "{ kind: fixture, path: state.json, environments: { production: prod } }")
      code, out, = cli("flags", "new-checkout", "enable", "--config", config)
      assert_equal 0, code
      assert JSON.parse(out).dig("state", "enabled")
      assert_equal "prod", JSON.parse(out)["env"]
      code, out, = cli("flags", "new-checkout", "set_cohort", "--config", config, "--cohort", "internal", "--expected-revision", "0")
      assert_equal 1, code
      assert_equal "revision_conflict", JSON.parse(out).dig("error", "code")
    end
  end

  def test_flags_command_adapter_and_failures
    Dir.mktmpdir do |dir|
      fixture = File.expand_path("../scripts/change_flags_fixture.rb", __dir__)
      config = write_change(dir, "{ kind: command, argv: [ruby, '#{fixture}'], timeout_s: 20, environments: { production: prod } }")
      ENV["CF_FLAGS_FIXTURE_PATH"] = File.join(dir, "cmd.json")
      code, out, = cli("flags", "new-checkout", "enable", "--config", config)
      assert_equal 0, code
      assert JSON.parse(out)["ok"]
      bad = write_change(dir, "{ kind: command, argv: [ruby, -e, 'exit 3'] }")
      code, out, = cli("flags", "new-checkout", "get", "--config", bad)
      assert_equal 1, code
      assert_equal "unavailable", JSON.parse(out).dig("error", "code")
    ensure
      ENV.delete("CF_FLAGS_FIXTURE_PATH")
    end
  end

  def test_flags_usage_errors
    assert_equal 2, cli("flags", "only-rollout").first
    Dir.mktmpdir do |dir|
      config = write_change(dir, "{ kind: fixture }")
      assert_equal 2, cli("flags", "missing", "get", "--config", config).first
    end
  end

  def test_the_reference_controller_passes_every_shipped_trace
    code, out, = cli("conformance", "--", "ruby", REFERENCE)
    assert_equal 0, code, out
    assert_match(/conformance: (\d+)\/\1 traces passed/, out)
    assert_operator Dir[File.join(ChangeDelivery::TRACES_DIR, "*.json")].length, :>=, 12
  end

  def test_a_controller_that_never_blocks_is_rejected
    lax = "puts JSON.generate('transitions' => JSON.parse($stdin.read)['steps'].each_index.map { |i| {'step'=>i,'verdict'=>'pass','action'=>'advance','stage'=>'everyone'} })"
    code, out, = cli("conformance", "--", "ruby", "-rjson", "-e", lax)
    assert_equal 1, code
    assert_includes out, "FAIL zero_traffic_unknown.json"
    assert_includes out, "expected"
  end

  def test_conformance_reports_a_crashing_controller_and_usage
    code, out, = cli("conformance", "--", "ruby", "-e", "exit 4")
    assert_equal 1, code
    assert_includes out, "controller exited 4"
    assert_equal 2, cli("conformance").first
    assert_equal 2, cli.first
  end
end
