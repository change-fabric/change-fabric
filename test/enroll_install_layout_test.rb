# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../install"

# Installs into a temp home and checks that the path each host's paid skill
# is told to load cf:enroll from resolves to a readable SKILL.md naming it,
# with and without XDG_CONFIG_HOME, and that every paid SKILL.md names that
# installed lookup rather than a repo path.
class EnrollInstallLayoutTest < Minitest::Test
  REPO = File.expand_path("..", __dir__)
  PAID = %w[roast b-roll walkthrough narrate music image imagine prototype].freeze

  def install(home, xdg)
    paths = Install::Paths.new(repo: REPO, home: home, xdg_config: xdg)
    capture_io { Install::Installer.new(paths: paths, ruby: RbConfig.ruby).install }
  end

  def host_paths(home, xdg)
    opencode = xdg.to_s.empty? ? File.join(home, ".config") : xdg
    { "claude" => File.join(home, ".claude", "skills", "cf:enroll", "SKILL.md"),
      "codex" => File.join(home, ".agents", "skills", "cf-enroll", "SKILL.md"),
      "copilot" => File.join(home, ".copilot", "skills", "cf-enroll", "SKILL.md"),
      "opencode" => File.join(opencode, "opencode", "skills", "cf-enroll", "SKILL.md"),
      "pi" => File.join(home, ".pi", "agent", "skills", "cf-enroll", "SKILL.md") }
  end

  def assert_layout(xdg_subdir)
    home = File.realpath(Dir.mktmpdir)
    xdg = xdg_subdir && File.join(home, xdg_subdir)
    install(home, xdg)
    host_paths(home, xdg).each do |host, path|
      assert File.readable?(path), "#{host}: #{path} missing"
      assert_match(/^name: (cf:enroll|cf-enroll)$/, File.read(path), host)
    end
  ensure
    FileUtils.remove_entry(home)
  end

  def test_every_host_resolves_cf_enroll_without_xdg = assert_layout(nil)

  def test_every_host_resolves_cf_enroll_with_xdg = assert_layout("xdg")

  def test_the_skill_names_each_host_lookup
    skill = File.read(File.join(REPO, "skills", "enroll", "SKILL.md"))
    [ "~/.claude/skills/cf:enroll/SKILL.md", "~/.agents/skills/cf-enroll/SKILL.md", "~/.copilot/skills/cf-enroll/SKILL.md",
      "$XDG_CONFIG_HOME/opencode/skills/cf-enroll/SKILL.md", "~/.config/opencode/skills/cf-enroll/SKILL.md",
      "~/.pi/agent/skills/cf-enroll/SKILL.md" ].each { |path| assert_includes skill, path }
  end

  def test_each_paid_skill_names_the_installed_lookup
    PAID.each do |name|
      text = File.read(File.join(REPO, "skills", name, "SKILL.md"))
      assert_includes text, "~/.claude/skills/cf:enroll/SKILL.md", name
      assert_includes text, "`cf-enroll`", name
      assert_includes text, "Exit 5 means", name
    end
  end
end
