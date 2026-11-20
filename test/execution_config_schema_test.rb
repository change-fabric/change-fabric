# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "yaml"
require_relative "../scripts/execution_config_schema"
require_relative "../scripts/tracker_policy"

# change_config.execution / outbound / trackers (spec 0.19.0), and the shape of
# the JSON schemas under schemas/ that the outbound send path and the
# execution adapters will validate against.
class ExecutionConfigSchemaTest < Minitest::Test
  SCHEMAS = File.expand_path("../schemas", __dir__)

  # The plan's documented config example, the widest valid shape.
  EXAMPLE = YAML.safe_load(<<~YAML)
    execution:
      ledger_dir: plan
      adapters:
        cloud_agent:
          kind: github_issue
          repo: owner/name
          trigger_label: ready-for-agent
          label_after_create: true
          bot_login: some-bot[bot]
          design_ref: true
    outbound:
      spend_usd_cap: 2.0
      hold_flush_minutes: 15
      stale_hold_hours: 24
      roast_target: 9
      roast_rounds: 4
      templates: [tracker_link@1, issue_link@1, pr_link@1, status_note@1]
      channels:
        github: { deliver: send }
        slack:  { deliver: draft, provider: slack, channel: "#builds" }
        jira:   { deliver: send, tracker: jira }
    trackers:
      jira:
        kind: jira
        site: example.atlassian.net
        provider: jira
        project: PROJ
  YAML

  def example = Marshal.load(Marshal.dump(EXAMPLE))
  def errors(cfg) = ExecutionConfigSchema.errors(cfg).join("\n")

  def test_documented_example_is_valid
    assert_empty ExecutionConfigSchema.errors(example)
  end

  def test_absent_blocks_are_valid
    assert_empty ExecutionConfigSchema.errors({})
  end

  def test_new_floor_and_cap_are_accepted
    cfg = example
    cfg["outbound"]["roast_target"] = 8
    cfg["outbound"]["roast_rounds"] = 5
    assert_empty ExecutionConfigSchema.errors(cfg)
  end

  def test_fixed_limits_cannot_be_loosened
    { "roast_target" => [ 7, /from 8 to 10/ ], "roast_rounds" => [ 6, /from 1 to 5/ ],
      "spend_usd_cap" => [ 2.5, /at most 2.0/ ], "hold_flush_minutes" => [ 30, /from 1 to 15/ ],
      "stale_hold_hours" => [ 0, /positive integer/ ] }.each do |key, (value, message)|
      cfg = example
      cfg["outbound"][key] = value
      assert_match message, errors(cfg), key
    end
  end

  def test_templates_are_name_at_version
    cfg = example
    cfg["outbound"]["templates"] = [ "pr_link", "pr_link@0", "pr_link@1", "pr_link@1" ]
    out = errors(cfg)
    assert_match(/"pr_link" is not name@version/, out)
    assert_match(/"pr_link@0" is not name@version/, out)
    assert_match(/lists pr_link@1 more than once/, out)
  end

  def test_channels
    cfg = example
    cfg["outbound"]["channels"]["email"] = { "deliver" => "send" }
    cfg["outbound"]["channels"]["github"]["deliver"] = "later"
    cfg["outbound"]["channels"]["jira"]["tracker"] = "linear"
    cfg["outbound"]["channels"]["slack"]["channel"] = "builds"
    out = errors(cfg)
    assert_match(/channels.email: unknown channel/, out)
    assert_match(/github.deliver must be one of send, draft/, out)
    assert_match(/jira.tracker names 'linear'/, out)
    assert_match(/slack.channel must be a #channel name/, out)
  end

  def test_github_issue_adapter_needs_its_wiring
    cfg = example
    adapter = cfg["execution"]["adapters"]["cloud_agent"]
    adapter.delete("trigger_label")
    adapter["repo"] = "not a repo"
    adapter["bot_login"] = "bad login!"
    adapter["ask_markers"] = []
    adapter["webhook"] = "x"
    out = errors(cfg)
    assert_match(/trigger_label must be a non-empty string/, out)
    assert_match(%r{repo must be owner/name}, out)
    assert_match(/bot_login must be a GitHub login/, out)
    assert_match(/ask_markers must be a non-empty list/, out)
    assert_match(/unknown key\(s\): webhook/, out)
  end

  def test_adapter_kind_and_ledger_dir
    cfg = example
    cfg["execution"]["adapters"]["cloud_agent"]["kind"] = "email"
    cfg["execution"]["ledger_dir"] = "relative/dir"
    out = errors(cfg)
    assert_match(/kind must be one of github_issue, fixture/, out)
    assert_match(/ledger_dir must be 'plan' or an absolute or ~ path/, out)
    cfg = example
    cfg["execution"]["ledger_dir"] = "~/ledgers/widgets"
    assert_empty ExecutionConfigSchema.errors(cfg)
  end

  def test_tracker_wiring
    cfg = example
    cfg["trackers"]["jira"] = { "kind" => "linear", "site" => "https://example.atlassian.net", "project" => "proj", "token" => "x" }
    out = errors(cfg)
    assert_match(/kind must be one of jira/, out)
    assert_match(/site must be a bare hostname/, out)
    assert_match(/provider must be a non-empty string/, out)
    assert_match(/project must be a project key/, out)
    assert_match(/unknown key\(s\): token/, out)
  end

  def load_schema(name) = JSON.parse(File.read(File.join(SCHEMAS, name)))

  def test_schema_files_parse_and_name_themselves
    { "cf.outbound.request-1.json" => "cf.outbound.request/1",
      "cf.adapter.request-1.json" => "cf.adapter.request/1",
      "cf.adapter.result-1.json" => "cf.adapter.result/1" }.each do |file, id|
      schema = load_schema(file)
      assert_equal "https://json-schema.org/draft/2020-12/schema", schema["$schema"]
      assert_equal id, schema["title"]
      assert_equal id, schema.dig("properties", "schema", "const")
      assert_equal false, schema["additionalProperties"], file
    end
  end

  # The envelope is a oneOf on operation: prose needs kind and body_file,
  # template needs template and values and forbids a body, typed needs fields
  # and forbids kind, body and template.
  def test_outbound_operation_branches
    branches = load_schema("cf.outbound.request-1.json")["oneOf"].to_h { |b| [ b["title"], b ] }
    assert_equal %w[prose template typed], branches.keys
    forbidden = ->(b) { b.dig("not", "anyOf").map { |r| r["required"].first } }

    assert_equal %w[kind body_file], branches["prose"]["required"]
    assert_equal %w[template values], branches["template"]["required"]
    assert_includes forbidden.call(branches["template"]), "body_file"
    assert_equal %w[fields], branches["typed"]["required"]
    assert_empty %w[kind body_file template] - forbidden.call(branches["typed"])
    typed_verbs = branches["typed"].dig("properties", "verb", "enum")
    assert_empty %w[label_set transition assign remote_link pr_ready pr_merge] - typed_verbs
    assert_empty typed_verbs & branches["prose"].dig("properties", "verb", "enum")
  end

  def test_outbound_prose_kinds
    kinds = load_schema("cf.outbound.request-1.json").dig("properties", "kind", "enum")
    assert_equal %w[issue comment reply design_ref], kinds
  end

  def test_adapter_ops_and_ticket_roles
    request = load_schema("cf.adapter.request-1.json")
    assert_equal %w[prepare activate observe classify], request.dig("properties", "op", "enum")
    role = Regexp.new(request.dig("$defs", "external", "properties", "tickets", "items", "properties", "role", "pattern"))
    %w[primary related-mention mention-on:pr_opened mention-on:release:production].each { |r| assert_match role, r }
    refute_match role, "owner"
  end
end
