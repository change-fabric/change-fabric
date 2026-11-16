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
    attr_reader :hidden

    def tty? = true

    def noecho
      @hidden = true
      yield self
    end
  end

  # A terminal with no way to hide input.
  class EchoingTty < StringIO
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

  def test_enroll_reads_the_key_with_echo_off
    stdin = FakeTty.new("#{FAKE}\n")
    assert_equal 0, run_cli("enroll", "openai", "--dir", @project, stdin: stdin).first
    assert stdin.hidden
  end

  def test_enroll_refuses_a_terminal_that_cannot_hide_input
    code, _out, err = run_cli("enroll", "openai", "--dir", @project, stdin: EchoingTty.new("#{FAKE}\n"))
    assert_equal 2, code
    assert_match(/real terminal/, err)
    assert_empty @requests
    refute File.exist?(CfSecretStore.root)
  end

  def test_real_stdin_supports_noecho
    assert_respond_to $stdin, :noecho
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

  def test_defer_records_per_provider_for_seven_days_by_default
    before = Time.now.utc
    code, out, = run_cli("defer", "gemini", "--dir", @project)
    assert_equal 0, code
    until_at = CfSecretStore.deferred_until(slug(@project), "gemini")
    assert_in_delta before + (7 * 86_400), until_at, 5
    assert_includes out, "until #{until_at.iso8601}"
    assert_nil CfSecretStore.meta(slug(@project)).dig("deferred", "openai")
  end

  def test_defer_days_takes_one_or_seven_only
    before = Time.now.utc
    assert_equal 0, run_cli("defer", "gemini", "--days", "1", "--dir", @project).first
    assert_in_delta before + 86_400, CfSecretStore.deferred_until(slug(@project), "gemini"), 5
    code, _, err = run_cli("defer", "gemini", "--days", "3", "--dir", @project)
    assert_equal CfKeys::EXIT_USAGE, code
    assert_includes err, "defer days must be one of 1, 7"
    assert_equal 1, run_cli("defer", "gemini", "--days", "x", "--dir", @project).first
  end

def test_confirm_inherit_clears_a_deferral
  run_cli("enroll", "openai", "--dir", @org)
  run_cli("defer", "openai", "--dir", @project)
  assert_equal 0, run_cli("confirm-inherit", "openai", "--dir", @project).first
  refute CfSecretStore.deferral_active?(slug(@project), "openai")
end

  def test_enroll_clears_a_deferral
    run_cli("defer", "openai", "--dir", @project)
    run_cli("enroll", "openai", "--dir", @project)
    refute CfSecretStore.deferral_active?(slug(@project), "openai")
    assert_nil CfSecretStore.deferred_until(slug(@project), "openai")
  end

  def test_status_reports_states_and_never_prints_values
    run_cli("enroll", "openai", "--dir", @project)
    run_cli("enroll", "elevenlabs", "--dir", @org, stdin: FakeTty.new("sk_#{'0f' * 24}\n"))
    run_cli("defer", "gemini", "--dir", @project)
    code, out, = run_cli("status", "--dir", @project)
    assert_equal 0, code
    assert_match(/openai: enrolled/, out)
    assert_match(/elevenlabs: inheritable from #{Regexp.escape(@org)} \(unconfirmed\)/, out)
    assert_match(/gemini: deferred until \d{4}-\d{2}-\d{2}T/, out)
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

  def test_enroll_records_expiry_label_and_tree_scope
    code, out, err = run_cli("enroll", "openai", "--dir", @org, "--expires", "2099-01-02",
                             "--label", "org billing", "--scope", "tree")
    assert_equal 0, code, err
    entry = CfSecretStore.enrollment(slug(@org), "openai")
    assert_equal "2099-01-02T00:00:00Z", entry["expires_at"]
    assert_equal "org billing", entry["label"]
    assert_equal "tree", entry["scope"]
    assert_match(/label "org billing", scope tree, expires 2099-01-02T00:00:00Z/, out)
    refute_includes out + err, FAKE
  end

  def test_enroll_defaults_to_project_scope_and_reenroll_clears_old_fields
    run_cli("enroll", "openai", "--dir", @project, "--expires", "2099-01-02", "--label", "old")
    run_cli("enroll", "openai", "--dir", @project)
    entry = CfSecretStore.enrollment(slug(@project), "openai")
    assert_nil entry["scope"]
    assert_nil entry["expires_at"]
    assert_nil entry["label"]
  end

  def test_enroll_with_a_bad_date_or_scope_is_a_usage_error_before_any_key_is_read
    stdin = FakeTty.new("#{FAKE}\n")
    code, _out, err = run_cli("enroll", "openai", "--dir", @project, "--expires", "next week", stdin: stdin)
    assert_equal 1, code
    assert_match(/not an ISO8601 date/, err)
    assert_match(/usage:/, err)
    assert_nil stdin.hidden
    assert_equal 1, run_cli("enroll", "openai", "--dir", @project, "--scope", "org").first
    assert_empty @requests
    refute File.exist?(CfSecretStore.root)
  end

  def test_expires_sets_and_corrects_the_date_without_a_tty
    run_cli("enroll", "openai", "--dir", @project, "--expires", "2099-01-02")
    code, out, = run_cli("expires", "openai", "2099-03-04T10:00:00+02:00", "--dir", @project,
                         stdin: StringIO.new)
    assert_equal 0, code
    assert_match(/now expires 2099-03-04T08:00:00Z/, out)
    assert_equal "2099-03-04T08:00:00Z", CfSecretStore.enrollment(slug(@project), "openai")["expires_at"]
    assert_equal FAKE, CfSecretStore.read_key(slug(@project), "openai")
    assert_equal 1, @requests.size
  end

  def test_expires_exits_3_when_nothing_is_enrolled_at_that_level
    code, _out, err = run_cli("expires", "openai", "2099-01-02", "--dir", @project)
    assert_equal 3, code
    assert_match(/no openai key enrolled at/, err)
    refute File.exist?(CfSecretStore.root)
  end

  def test_expires_rejects_a_bad_date_and_a_missing_date
    run_cli("enroll", "openai", "--dir", @project)
    assert_equal 1, run_cli("expires", "openai", "soon", "--dir", @project).first
    assert_equal 1, run_cli("expires", "openai", "--dir", @project).first
    assert_nil CfSecretStore.enrollment(slug(@project), "openai")["expires_at"]
  end

  def test_status_shows_label_scope_expiry_and_days_but_no_key_bytes
    run_cli("enroll", "openai", "--dir", @org, "--expires", "2000-01-01", "--label", "org", "--scope", "tree")
    run_cli("enroll", "gemini", "--dir", @project, "--label", "proj", stdin: FakeTty.new("AIza#{'B' * 35}\n"))
    code, out, = run_cli("status", "--dir", @project)
    assert_equal 0, code
    assert_match(/openai: inherited from #{Regexp.escape(@org)} \(label "org", scope tree, expires 2000-01-01T00:00:00Z \(expired\)\)/, out)
    assert_match(/gemini: enrolled \(label "proj"\)/, out)
    refute_includes out, FAKE
    refute_includes out, "BBBBBBBB"
  end

  def test_status_shows_days_left
    date = (Time.now.utc + (10 * 86_400) + 3600).strftime("%Y-%m-%dT%H:%M:%SZ")
    run_cli("enroll", "openai", "--dir", @project, "--expires", date)
    assert_match(/openai: enrolled \(expires #{date} \(10 days left\)\)/, run_cli("status", "--dir", @project)[1])
  end
end
