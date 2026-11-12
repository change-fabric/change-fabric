# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/cf_secret_store"
require_relative "../scripts/cf_project_identity"

class CfSecretStoreTest < Minitest::Test
  FAKE = "sk-proj-FAKEFAKEFAKEFAKEFAKEFAKEFAKE"

  def setup
    @home = Dir.mktmpdir
    @prev = ENV.fetch("HOME", nil)
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def mode(path) = File.stat(path).mode & 0o777

  def test_root_lives_under_the_injected_home
    assert_equal File.join(@home, ".claude", "cf", "secrets"), CfSecretStore.root
  end

  def test_write_key_sets_private_modes
    path = CfSecretStore.write_key("abc", "openai", FAKE)
    assert_equal 0o700, mode(CfSecretStore.root)
    assert_equal 0o700, mode(CfSecretStore.dir("abc"))
    assert_equal 0o600, mode(path)
    assert_equal 0o600, mode(CfSecretStore.meta_path("abc"))
    assert_equal ".openai", File.basename(path)
  end

  def test_read_key_round_trips_and_key_reports_presence
    refute CfSecretStore.key?("abc", "gemini")
    CfSecretStore.write_key("abc", "gemini", "  #{FAKE}\n")
    assert CfSecretStore.key?("abc", "gemini")
    assert_equal FAKE, CfSecretStore.read_key("abc", "gemini")
  end

  def test_meta_never_holds_key_bytes
    identity = CfProjectIdentity::Identity.new(id: "dir:/p", slug: "abc", root: "/p")
    CfSecretStore.describe(identity)
    CfSecretStore.write_key("abc", "openai", FAKE)
    text = File.read(CfSecretStore.meta_path("abc"))
    refute_includes text, FAKE
    refute_includes text, FAKE[-8..]
    meta = CfSecretStore.meta("abc")
    assert_equal "dir:/p", meta["id"]
    assert meta.dig("enrolled", "openai", "at")
  end

  def test_remove_key_deletes_the_file_and_the_enrolled_entry
    CfSecretStore.write_key("abc", "openai", FAKE)
    CfSecretStore.remove_key("abc", "openai")
    refute CfSecretStore.key?("abc", "openai")
    assert_nil CfSecretStore.meta("abc").dig("enrolled", "openai")
  end

  def test_update_meta_records_deferrals_and_inherits
    CfSecretStore.update_meta("abc") { |m| (m["deferred"] ||= {})["gemini"] = true }
    CfSecretStore.update_meta("abc") { |m| (m["confirmed_inherits"] ||= {})["openai"] = "dir:/home" }
    meta = CfSecretStore.meta("abc")
    assert_equal true, meta.dig("deferred", "gemini")
    assert_equal "dir:/home", meta.dig("confirmed_inherits", "openai")
  end

  def test_corrupt_meta_reads_as_empty
    CfSecretStore.ensure_dir("abc")
    File.write(CfSecretStore.meta_path("abc"), "{not json")
    assert_equal({}, CfSecretStore.meta("abc"))
  end

  def test_empty_key_is_rejected
    assert_raises(ArgumentError) { CfSecretStore.write_key("abc", "openai", " ") }
    refute File.exist?(CfSecretStore.dir("abc"))
  end

  def test_slugs_lists_project_dirs
    CfSecretStore.write_key("b", "openai", FAKE)
    CfSecretStore.write_key("a", "openai", FAKE)
    assert_equal %w[a b], CfSecretStore.slugs
  end
end
