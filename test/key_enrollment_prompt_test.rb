# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "../scripts/key_enrollment_prompt"
require_relative "../scripts/cf_host_hook"

class KeyEnrollmentPromptTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/key_enrollment_prompt.rb", __dir__)

  def setup
    @home = File.realpath(Dir.mktmpdir)
    @prev = ENV.fetch("HOME", nil)
    ENV["HOME"] = @home
    @org = File.join(@home, "org")
    @project = File.join(@org, "proj")
    @sibling = File.join(@org, "sib")
    [ @project, @sibling ].each { |d| FileUtils.mkdir_p(d) }
    require_providers("openai" => [ "cf:image", "cf:roast" ])
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def require_providers(map)
    path = File.join(@home, ".local", "share", "change-fabric", "installation.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate("version" => 1, "entries" => [], "required_providers" => map))
  end

  def slug(dir) = CfProjectIdentity.for_explicit_dir(dir).slug

  def context(cwd = @project) = KeyEnrollmentPrompt.new({ "cwd" => cwd }, home: @home).context

  def test_missing_provider_asks_with_the_snippet_and_a_defer_option
    text = context
    assert_includes text, "AskUserQuestion"
    assert_includes text, "OpenAI (openai, used by cf:image, cf:roast)"
    assert_includes text, "cf_keys.rb enroll openai --dir #{@project}"
    assert_includes text, "cf_keys.rb defer openai --dir #{@project}"
    refute_includes text, "confirm-inherit"
  end

  def test_inheritable_ancestor_adds_the_confirm_inherit_option
    CfSecretStore.write_key(slug(@org), "openai", "sk-org-fake")
    text = context
    assert_includes text, "Use the key enrolled at #{@org}"
    assert_includes text, "cf_keys.rb confirm-inherit openai --dir #{@project}"
    refute_includes text, "sk-org-fake"
  end

  def test_a_malformed_entry_skips_only_itself
    require_providers("elevenlabs" => "cf:narrate", "openai" => [ "cf:image" ])
    text = context
    assert_includes text, "OpenAI (openai, used by cf:image)"
    refute_includes text, "elevenlabs"
  end

  def test_enrolled_or_confirmed_projects_are_quiet
    CfSecretStore.write_key(slug(@project), "openai", "sk-own-fake")
    assert_nil context
    CfSecretStore.write_key(slug(@org), "openai", "sk-org-fake")
    CfSecretStore.update_meta(slug(@sibling)) { |m| m["confirmed_inherits"] = { "openai" => "dir:#{@org}" } }
    assert_nil context(@sibling)
  end

  def test_deferral_silences_only_that_project
    CfSecretStore.defer(slug(@project), "openai")
    assert_nil context
    assert_includes context(@sibling), "cf_keys.rb enroll openai --dir #{@sibling}"
  end

  # Phase boundary: while this hook is still installed, it honors the new
  # deferred_until. An active one silences the provider, a lapsed one does
  # not, and a legacy boolean counts as lapsed.
  def test_active_deferred_until_silences_and_lapsed_or_legacy_does_not
    CfSecretStore.defer(slug(@project), "openai", days: 1, now: Time.now - 3600)
    assert_nil context
    CfSecretStore.defer(slug(@project), "openai", days: 1, now: Time.now - (25 * 3600))
    assert_includes context, "cf_keys.rb enroll openai --dir #{@project}"
    CfSecretStore.update_meta(slug(@project)) { |m| m["deferred"] = { "openai" => true } }
    assert_includes context, "cf_keys.rb enroll openai --dir #{@project}"
  end

  def test_deferral_is_per_provider
    require_providers("openai" => [ "cf:image" ], "gemini" => [ "cf:b-roll" ])
    CfSecretStore.defer(slug(@project), "openai")
    text = context
    refute_includes text, "enroll openai"
    assert_includes text, "enroll gemini"
  end

  def test_newly_required_provider_prompts_an_already_enrolled_project
    CfSecretStore.write_key(slug(@project), "openai", "sk-own-fake")
    assert_nil context
    require_providers("openai" => [ "cf:image" ], "elevenlabs" => [ "cf:narrate" ])
    text = context
    assert_includes text, "ElevenLabs (elevenlabs, used by cf:narrate)"
    refute_includes text, "enroll openai"
  end

  def test_no_installation_record_is_quiet
    FileUtils.rm_rf(File.join(@home, ".local"))
    assert_nil context
  end

  def test_cli_emits_session_start_context_and_fails_silent
    out, _err, status = Open3.capture3({ "HOME" => @home }, RbConfig.ruby, SCRIPT, stdin_data: JSON.generate("cwd" => @project))
    assert status.success?
    assert_equal "SessionStart", JSON.parse(out).dig("hookSpecificOutput", "hookEventName")
    out, err, status = Open3.capture3({ "HOME" => @home }, RbConfig.ruby, SCRIPT, stdin_data: "not json")
    assert status.success?
    assert_empty err
    assert_includes out, "hookSpecificOutput" if out != ""
  end

  NOW = Time.utc(2026, 6, 1, 12)

  def enroll(dir, provider, value, **fields)
    s = slug(dir)
    CfSecretStore.write_key(s, provider, value)
    CfSecretStore.update_meta(s) { |m| m["root"] = dir }
    CfSecretStore.update_enrollment(s, provider, fields)
  end

  def scan = KeyEnrollmentPrompt.new({ "cwd" => @project }, home: @home, now: NOW).context

  def test_expiry_scan_names_expired_and_soon_keys_across_projects
    enroll(@project, "openai", "sk-own-fake", expires_at: "2026-05-31T00:00:00Z", label: "team key")
    enroll(@sibling, "gemini", "gm-sib-fake", expires_at: "2026-06-02T06:00:00Z")
    enroll(@org, "elevenlabs", "el-org-fake", expires_at: "2026-07-01T00:00:00Z")
    text = scan
    assert_includes text, "expired or expiring within 24h"
    assert_includes text, "- openai \"team key\" at #{@project}: expired"
    assert_includes text, "cf_keys.rb enroll openai --dir #{@project}"
    assert_includes text, "- gemini at #{@sibling}: expires within 24h"
    assert_includes text, "cf_keys.rb enroll gemini --dir #{@sibling}"
    refute_includes text, "elevenlabs"
    %w[sk-own-fake gm-sib-fake el-org-fake].each { |key| refute_includes text, key }
  end

  def test_expiry_scan_is_quiet_without_dates_and_skips_malformed_meta
    enroll(@project, "openai", "sk-own-fake")
    FileUtils.mkdir_p(File.join(CfSecretStore.root, "broken"))
    File.write(File.join(CfSecretStore.root, "broken", "meta.json"), "{not json")
    CfSecretStore.update_meta("odd") { |m| m.merge!("root" => "/x", "enrolled" => { "openai" => "nope", "bogus" => {} }) }
    assert_nil scan
  end

  def test_expiry_scan_runs_without_an_installation_record
    FileUtils.rm_rf(File.join(@home, ".local"))
    enroll(@sibling, "openai", "sk-sib-fake", expires_at: "2026-05-01")
    assert_includes scan, "- openai at #{@sibling}: expired"
  end

  def test_codex_session_start_carries_the_prompt
    result = CfHostHook.new(host: "codex", event: "SessionStart", payload: { "session_id" => "s", "cwd" => @project },
                            root: File.join(@home, "state"), home: @home, skills: []).call
    assert_includes result.dig("hookSpecificOutput", "additionalContext"), "cf_keys.rb enroll openai"
  end
end
