# frozen_string_literal: true

require_relative "test_helpers"

class SkillDetectTest < Minitest::Test
  include SkillTempHome
  include SkillFactory

  def setup
    super
    @skills = Dir.mktmpdir
    @proj = Dir.mktmpdir
    skill_dir("ruby", auto: { "detect" => [ "Gemfile" ] })
    skill_dir("refactoring", auto: { "all_code" => true })
    skill_dir("python", auto: { "detect" => [ "pyproject.toml" ] })
  end

  def teardown
    FileUtils.remove_entry(@skills)
    FileUtils.remove_entry(@proj)
    super
  end

  def announce(session: "s1")
    io = StringIO.new
    event = { "session_id" => session, "cwd" => @proj }
    SkillDetect.new(event, skills: SkillRegistry.load(@skills)).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "additionalContext")
  end

  def test_announces_detected_and_always_on_skills_only
    FileUtils.touch(File.join(@proj, "Gemfile"))
    text = announce
    assert_includes text, "ruby"
    assert_includes text, "refactoring"
    refute_includes text, "python"
  end

  def test_announces_once_per_session
    FileUtils.touch(File.join(@proj, "Gemfile"))
    assert announce
    assert_nil announce, "second SessionStart should not re-announce"
  end
end
