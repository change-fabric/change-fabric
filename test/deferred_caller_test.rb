# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "enroll_helpers"
require_relative "../scripts/image"

# A paid script under an active deferral exits 5 with the one-line note and
# makes no provider call, even with a key enrolled. Every caller passes the
# exit through unchanged: no cf_enroll line, no error line, no exit 1 or 4.
class DeferredCallerTest < Minitest::Test
  include EnrollHelpers

  SCRIPTS = File.expand_path("../scripts", __dir__)
  NOTE = /\A\[cf\] (\w+) deferred until \d{4}-\d{2}-\d{2}T\S+; skipping paid step\n\z/

  def setup
    @project = File.realpath(Dir.mktmpdir)
    @cache = File.join(@project, ".cache")
  end

  def teardown = FileUtils.remove_entry(@project)

  def defer!(provider) = CfSecretStore.defer(CfProjectIdentity.for(@project).slug, provider)

  def test_image_in_process_raises_deferred_with_no_http_call
    with_enrolled("openai", root: @project) do
      defer!("openai")
      calls = []
      http = Object.new
      http.define_singleton_method(:request) { |*a| calls << a }
      out = StringIO.new
      exit_err = nil
      _, note = capture_io do
        exit_err = Dir.chdir(@project) do
          assert_raises(WalkthroughEnv::Deferred) do
            Image::Cli.run([ "a red apple", "--cache", @cache ], out: out, err: StringIO.new, http: http)
          end
        end
      end
      assert_equal 5, exit_err.status
      assert_match NOTE, note
      assert_empty calls
      assert_empty enroll_lines(out.string)
    end
  end

  def test_paid_scripts_exit_5_with_one_note_and_no_enroll_line
    with_enrolled("openai", "elevenlabs", root: @project) do
      defer!("openai")
      defer!("elevenlabs")
      { "openai" => [ "image.rb", "a red apple", "--cache", @cache ],
        "elevenlabs" => [ "elevenlabs.rb", "narrate", "--text", "hello there", "--voice", "v1", "--cache", @cache ] }
        .each do |provider, argv|
        out, err, status = Open3.capture3({ "HOME" => ENV.fetch("HOME") }, RbConfig.ruby, File.join(SCRIPTS, argv.first),
                                          *argv.drop(1), chdir: @project)
        assert_equal 5, status.exitstatus, "#{argv.first}: #{out}#{err}"
        notes = err.lines.grep(/\A\[cf\]/)
        assert_equal 1, notes.size, err
        assert_equal provider, notes.first[NOTE, 1]
        assert_empty enroll_lines(out), out
        refute_match(/^error:/, out)
      end
    end
  end
end
