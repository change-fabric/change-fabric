# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "yaml"
require_relative "../scripts/cf_secrets"

# Points HOME at a tmpdir so CfSecrets reads a throwaway store, never the
# real one. `enrolled: true` records this project as process env only.
module EnrollHelpers
  def with_store(enrolled: false)
    home = Dir.mktmpdir
    saved = ENV.fetch("HOME", nil)
    saved_pin = ENV.fetch("CF_SECRETS_ENV", nil)
    ENV.delete("CF_SECRETS_ENV")
    if enrolled
      path = CfSecrets.store_path(home)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump("projects" => { CfSecrets.project_key => { "env_file" => CfSecrets::ENV_ONLY } }))
    end
    ENV["HOME"] = home
    yield
  ensure
    ENV["HOME"] = saved
    saved_pin.nil? ? ENV.delete("CF_SECRETS_ENV") : ENV["CF_SECRETS_ENV"] = saved_pin
    FileUtils.rm_rf(home)
  end

  def enroll_lines(text)
    text.lines.map { |l| JSON.parse(l) rescue nil }.compact.select { |h| h.is_a?(Hash) && h.key?("cf_enroll") }
  end

  def assert_one_enroll_line(text, provider)
    lines = enroll_lines(text)
    assert_equal 1, lines.size, text
    assert_equal provider, lines.first.dig("cf_enroll", "provider")
    assert_equal CfSecrets.project_key, lines.first.dig("cf_enroll", "project_key")
  end
end
