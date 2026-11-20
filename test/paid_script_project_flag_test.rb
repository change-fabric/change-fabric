# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "stringio"
require "rbconfig"
require "tmpdir"
require_relative "key_project_helpers"
require_relative "../scripts/key_project"
require_relative "../scripts/elevenlabs"
require_relative "../scripts/roast"
require_relative "../scripts/roast_video"
require_relative "../scripts/image"
require_relative "../scripts/incident_report"

# Every paid script takes --project DIR (the directory whose enrolled key paid
# calls use). No network, no key: option parsing and the refusal paths only.
class PaidScriptProjectFlagTest < Minitest::Test
  include KeyProjectHelpers

  SCRIPTS = File.expand_path("../scripts", __dir__)

  # The scripts the plan names; prototype_imagegen.rb, and the elevenlabs,
  # roast and b_roll libraries, take the same directory as key_cwd:.
  CLI_SCRIPTS = %w[roast elevenlabs b_roll walkthrough_render roast_video image incident_report].freeze

  def setup = @dir = Dir.mktmpdir

  def teardown = FileUtils.rm_rf(@dir)

  def test_elevenlabs_parses_the_flag
    assert_equal @dir, ElevenLabs::Cli.parse([ "--text", "hi", "--project", @dir ])[:project]
  end

  def test_roast_parses_the_flag
    brief = File.join(@dir, "brief.md").tap { |p| File.write(p, "b") }
    opts = Roast::Cli.parse([ "--brief", brief, "--text", brief, "--project", @dir, "--cache", @dir ])
    assert_equal @dir, opts[:project]
  end

  def test_roast_video_parses_the_flag
    mp4 = File.join(@dir, "a.mp4").tap { |p| File.write(p, "x") }
    brief = File.join(@dir, "brief.md").tap { |p| File.write(p, "b") }
    opts = RoastVideo::Cli.parse([ "--video", mp4, "--brief", brief, "--project", @dir, "--cache", @dir ])
    assert_equal @dir, opts[:project]
  end

  def test_image_parses_the_flag
    assert_equal @dir, Image::Cli.parse([ "a prompt", "--project", @dir ])[:project]
  end

  def test_incident_report_accepts_the_flag_as_an_option
    cli = IncidentReport::Cli.new([], out: StringIO.new, err: StringIO.new)
    assert_equal @dir, cli.send(:parse, [ "--project", @dir ])["project"]
  end

  def test_the_usage_of_each_option_parser_cli_names_the_flag
    [ ElevenLabs::Cli::USAGE, Roast::USAGE, RoastVideo::USAGE, Image::USAGE, IncidentReport::Cli::USAGE ].each do |usage|
      assert_includes usage, "--project"
    end
  end

  def run_script(name, *args)
    Open3.capture2e(RbConfig.ruby, File.join(SCRIPTS, "#{name}.rb"), *args, chdir: @dir)
  end

  def test_b_roll_script_recognizes_the_flag_and_refuses_a_missing_directory
    out, status = run_script("b_roll", "img.png", "prompt", File.join(@dir, "cache"), "--project", File.join(@dir, "nope"))
    refute status.success?
    assert_includes out, "--project"
    assert_includes out, "not a directory"
  end

  def test_walkthrough_render_script_recognizes_the_flag_and_refuses_a_missing_directory
    out, status = run_script("walkthrough_render", "walkthrough/x", "--project", File.join(@dir, "nope"))
    refute status.success?
    assert_includes out, "not a directory"
  end

  def test_scripts_refuse_a_scratchpad_project_and_name_it
    scratch = make_scratchpad!
    out, status = run_script("b_roll", "img.png", "prompt", File.join(@dir, "cache"), "--project", scratch)
    refute status.success?
    assert_includes out, scratch
    assert_includes out, "is a Claude Code session scratchpad"
    refute_includes out, "cf_enroll"
  ensure
    remove_scratchpad!
  end

  def test_every_script_that_reads_a_paid_key_resolves_it_against_a_cwd
    callers = Dir[File.join(SCRIPTS, "*.rb")].select { |f| File.read(f).match?(/WalkthroughEnv\.(openai|elevenlabs|gemini)_key!/) }
    refute_empty callers
    callers.each do |file|
      source = File.read(file)
      assert_match(/_key!\(cwd: /, source, "#{File.basename(file)} must pass the resolved project as cwd:")
    end
  end

  def test_every_cli_script_resolves_through_key_project
    CLI_SCRIPTS.each do |name|
      source = File.read(File.join(SCRIPTS, "#{name}.rb"))
      assert_includes source, "KeyProject.", "#{name}.rb must resolve --project through KeyProject"
      assert_includes source, "key_project", "#{name}.rb must require key_project"
    end
  end
end
