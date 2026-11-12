# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require_relative "../scripts/cf_secrets"

# Points HOME at a tmpdir so CfSecrets reads a throwaway per-project store,
# never the real one, and writes fake keys into it for the project the given
# root belongs to. Nothing here ever reads a real key.
module EnrollHelpers
  FAKE_KEYS = {
    "openai" => "sk-test-secret",
    "elevenlabs" => "el-test-secret",
    "gemini" => "gemini-test-secret"
  }.freeze

  # Block form: providers listed are enrolled (a Hash maps provider => fake
  # key); none listed means the project is unenrolled. Nests inside a setup
  # that called enroll_home!, restoring that HOME afterwards.
  def with_enrolled(*providers, root: Dir.pwd)
    saved = ENV.fetch("HOME", nil)
    home = Dir.mktmpdir
    ENV["HOME"] = home
    write_fake_keys(providers, root)
    yield
  ensure
    ENV["HOME"] = saved
    FileUtils.rm_rf(home)
  end

  # Setup/teardown form of with_enrolled.
  def enroll_home!(*providers, root: Dir.pwd)
    @enroll_saved_home = ENV.fetch("HOME", nil)
    @enroll_home = Dir.mktmpdir
    ENV["HOME"] = @enroll_home
    @enroll_root = root
    write_fake_keys(providers, root)
  end

  def write_fake_keys(providers, root)
    keys = providers.first.is_a?(Hash) ? providers.first : providers.to_h { |p| [ p.to_s, FAKE_KEYS.fetch(p.to_s) ] }
    slug = CfProjectIdentity.for(root).slug
    keys.each { |provider, key| CfSecretStore.write_key(slug, provider.to_s, key) }
  end

  def restore_home!
    return unless @enroll_home

    ENV["HOME"] = @enroll_saved_home
    FileUtils.rm_rf(@enroll_home)
    @enroll_home = nil
  end

  def unenroll!(provider) = CfSecretStore.remove_key(enroll_slug, provider)

  def enroll_slug = CfProjectIdentity.for(@enroll_root).slug

  def enroll_lines(text)
    text.lines.map { |l| JSON.parse(l) rescue nil }.compact.select { |h| h.is_a?(Hash) && h.key?("cf_enroll") }
  end

  def assert_one_enroll_line(text, provider, root: Dir.pwd)
    lines = enroll_lines(text)
    assert_equal 1, lines.size, text
    assert_equal provider, lines.first.dig("cf_enroll", "provider")
    assert_equal CfProjectIdentity.for(root).root, lines.first.dig("cf_enroll", "project_root")
    assert_includes lines.first.dig("cf_enroll", "snippet"), "cf_keys.rb enroll #{provider}"
  end
end
