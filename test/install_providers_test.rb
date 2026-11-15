# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../install"
require_relative "../scripts/skill_providers"

class InstallProvidersTest < Minitest::Test
  def setup = @dir = Dir.mktmpdir
  def teardown = FileUtils.remove_entry(@dir)

  def skill(name, front)
    dir = File.join(@dir, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), "---\nname: cf:#{name}\n#{front}---\nbody\n")
    dir
  end

  def test_collects_providers_per_skill
    dirs = [ skill("image", "providers: [openai]\n"), skill("walk", "providers: [openai, gemini]\n"), skill("plain", "") ]
    assert_equal({ "openai" => %w[cf:image cf:walk], "gemini" => %w[cf:walk] }, SkillProviders.collect(dirs))
  end

  def test_unknown_provider_fails_loudly
    err = assert_raises(SkillProviders::UnknownProvider) { SkillProviders.collect([ skill("x", "providers: [acme]\n") ]) }
    assert_includes err.message, "cf:x declares unknown provider \"acme\""
  end

  def test_the_repo_declares_the_paid_skills
    repo = File.expand_path("..", __dir__)
    required = SkillProviders.collect(Dir.glob(File.join(repo, "skills", "*")).select { |p| File.directory?(p) })
    assert_equal %w[cf:image cf:imagine cf:prototype cf:roast cf:walkthrough], required["openai"]
    assert_equal %w[cf:music cf:narrate cf:walkthrough], required["elevenlabs"]
    assert_equal %w[cf:b-roll cf:walkthrough], required["gemini"]
  end

  def test_install_records_required_providers_and_reports_them
    home = Dir.mktmpdir
    paths = Install::Paths.new(repo: File.expand_path("..", __dir__), home: home)
    out, = capture_io { Install::Installer.new(paths: paths, ruby: "/usr/bin/ruby").install }
    data = JSON.parse(File.read(File.join(paths.runtime_root, "installation.json")))
    assert_includes data.dig("required_providers", "gemini"), "cf:b-roll"
    assert_match(/paid providers required: .*gemini \(cf:b-roll, cf:walkthrough\)/, out)
    assert File.file?(File.join(paths.state_root, "config", "providers.yml"))
  ensure
    FileUtils.remove_entry(home)
  end
end
