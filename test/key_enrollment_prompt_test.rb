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

  def test_enrolled_or_confirmed_projects_are_quiet
    CfSecretStore.write_key(slug(@project), "openai", "sk-own-fake")
    assert_nil context
    CfSecretStore.write_key(slug(@org), "openai", "sk-org-fake")
    CfSecretStore.update_meta(slug(@sibling)) { |m| m["confirmed_inherits"] = { "openai" => "dir:#{@org}" } }
    assert_nil context(@sibling)
  end

  def test_deferral_silences_only_that_project
    CfSecretStore.update_meta(slug(@project)) { |m| m["deferred"] = { "openai" => true } }
    assert_nil context
    assert_includes context(@sibling), "cf_keys.rb enroll openai --dir #{@sibling}"
  end

  def test_deferral_is_per_provider
    require_providers("openai" => [ "cf:image" ], "gemini" => [ "cf:b-roll" ])
    CfSecretStore.update_meta(slug(@project)) { |m| m["deferred"] = { "openai" => true } }
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

  def test_codex_session_start_carries_the_prompt
    result = CfHostHook.new(host: "codex", event: "SessionStart", payload: { "session_id" => "s", "cwd" => @project },
                            root: File.join(@home, "state"), home: @home, skills: []).call
    assert_includes result.dig("hookSpecificOutput", "additionalContext"), "cf_keys.rb enroll openai"
  end
end
