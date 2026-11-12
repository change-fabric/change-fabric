# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../scripts/cf_keys"

class CfKeysTest < Minitest::Test
  FAKE = "sk-proj-FAKEFAKEFAKEFAKEFAKEFAKEFAKE"

  # Stands in for a terminal: tty? is true and the typed key comes from gets.
  class FakeTty < StringIO
    def tty? = true
  end

  Response = Struct.new(:code)

  def setup
    @home = Dir.mktmpdir
    @prev = ENV.fetch("HOME", nil)
    ENV["HOME"] = @home
    @org = File.join(File.realpath(@home), "org")
    @project = File.join(@org, "proj")
    FileUtils.mkdir_p(@project)
    @requests = []
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def http(code: "200", raise_with: nil)
    lambda do |req, uri|
      @requests << [ req, uri ]
      raise raise_with if raise_with

      Response.new(code)
    end
  end

  def run_cli(*argv, stdin: FakeTty.new("#{FAKE}\n"), http: self.http)
    out = StringIO.new
    err = StringIO.new
    code = CfKeys.new(stdin: stdin, stdout: out, stderr: err, cwd: @project,
                      validator: CfKeyValidator.new(http: http)).run(argv)
    [ code, out.string, err.string ]
  end

  def slug(dir) = CfProjectIdentity.for_explicit_dir(dir).slug

  def test_enroll_refuses_piped_input_and_writes_nothing
    code, _out, err = run_cli("enroll", "openai", "--dir", @project, stdin: StringIO.new("#{FAKE}\n"))
    assert_equal 2, code
    assert_match(/real terminal/, err)
    refute File.exist?(CfSecretStore.root)
    assert_empty @requests
  end

  def test_enroll_validates_then_stores_without_echoing_the_key
    code, out, err = run_cli("enroll", "openai", "--dir", @project)
    assert_equal 0, code, err
    assert_equal "enrolled openai for #{@project}\n", out
    refute_includes out + err, FAKE
    assert_equal FAKE, CfSecretStore.read_key(slug(@project), "openai")
    req, uri = @requests.first
    assert_equal "https://api.openai.com/v1/models", uri.to_s
    assert_equal "Bearer #{FAKE}", req["Authorization"]
  end

  def test_header_auth_providers_send_their_named_header
    key = "AIza#{'B' * 35}"
    run_cli("enroll", "gemini", "--dir", @project, stdin: FakeTty.new("#{key}\n"))
    assert_equal key, @requests.first.first["x-goog-api-key"]
  end

  def test_rejected_key_exits_3_and_stores_nothing
    code, out, err = run_cli("enroll", "openai", "--dir", @project, http: http(code: "401"))
    assert_equal 3, code
    assert_match(/HTTP 401/, err)
    refute_includes out + err, FAKE
    refute CfSecretStore.key?(slug(@project), "openai")
  end

  def test_offline_enrollment_fails_with_exit_3
    code, _out, err = run_cli("enroll", "openai", "--dir", @project, http: http(raise_with: SocketError.new("offline")))
    assert_equal 3, code
    assert_match(/could not reach openai/, err)
    refute CfSecretStore.key?(slug(@project), "openai")
  end

  def test_shape_mismatch_warns_but_validation_decides
    code, _out, err = run_cli("enroll", "openai", "--dir", @project, stdin: FakeTty.new("odd-shaped-key\n"))
    assert_equal 0, code
    assert_match(/does not look like/, err)
  end

  def test_confirm_inherit_fails_without_an_enrolled_ancestor
    code, _out, err = run_cli("confirm-inherit", "openai", "--dir", @project)
    assert_equal 1, code
    assert_match(/no enrolled openai key above/, err)
    assert_nil CfSecretStore.meta(slug(@project)).dig("confirmed_inherits", "openai")
  end

  def test_confirm_inherit_records_the_nearest_enrolled_ancestor
    run_cli("enroll", "openai", "--dir", @org)
    code, out, = run_cli("confirm-inherit", "openai", "--dir", @project)
    assert_equal 0, code
    assert_match(/uses the openai key enrolled at #{Regexp.escape(@org)}/, out)
    assert_equal "dir:#{@org}", CfSecretStore.meta(slug(@project)).dig("confirmed_inherits", "openai")
  end

  def test_defer_records_per_provider
    assert_equal 0, run_cli("defer", "gemini", "--dir", @project).first
    meta = CfSecretStore.meta(slug(@project))
    assert_equal true, meta.dig("deferred", "gemini")
    assert_nil meta.dig("deferred", "openai")
  end

  def test_status_reports_states_and_never_prints_values
    run_cli("enroll", "openai", "--dir", @project)
    run_cli("enroll", "elevenlabs", "--dir", @org, stdin: FakeTty.new("sk_#{'0f' * 24}\n"))
    run_cli("defer", "gemini", "--dir", @project)
    code, out, = run_cli("status", "--dir", @project)
    assert_equal 0, code
    assert_match(/openai: enrolled/, out)
    assert_match(/elevenlabs: inheritable from #{Regexp.escape(@org)} \(unconfirmed\)/, out)
    assert_match(/gemini: deferred/, out)
    refute_includes out, FAKE
    refute_includes out, "0f0f0f"
  end

  def test_remove_requires_a_tty
    run_cli("enroll", "openai", "--dir", @project)
    assert_equal 2, run_cli("remove", "openai", "--dir", @project, stdin: StringIO.new).first
    assert CfSecretStore.key?(slug(@project), "openai")
    assert_equal 0, run_cli("remove", "openai", "--dir", @project).first
    refute CfSecretStore.key?(slug(@project), "openai")
  end

  def test_unknown_provider_is_a_usage_error
    assert_equal 1, run_cli("enroll", "acme", "--dir", @project).first
  end

  def test_snippet_quotes_the_root
    assert_equal "ruby ~/.claude/cf/bin/cf_keys.rb enroll openai --dir /a\\ b", CfKeys.snippet("openai", "/a b")
  end
end
