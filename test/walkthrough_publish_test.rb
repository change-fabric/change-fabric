# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../scripts/walkthrough_publish"

# The walkthrough publish step with every collaborator stubbed: no HTTP, no gh,
# no docker. Covers target choice, the size gate, and the idempotent splice.
class WalkthroughPublishTest < Minitest::Test
  P = WalkthroughPublish

  # Records gh calls; answers from a table keyed by the argv prefix.
  class FakeGh
    attr_reader :calls

    def initialize(answers = {})
      @answers = answers
      @calls = []
    end

    def call(*argv, stdin: nil)
      @calls << [ argv.map(&:to_s), stdin ]
      key = argv.map(&:to_s).first(3).join(" ")
      @answers.fetch(key, [ "", true ])
    end
  end

  FakeUploader = Struct.new(:url, :error, :uploaded) do
    def upload(path)
      uploaded << path
      ChangeScreenshotUpload::Result.new(path: path, url: url, error: error)
    end
  end

  Status = Struct.new(:ok) do
    def success? = ok
  end

  def with_mp4(bytes)
    Dir.mktmpdir do |dir|
      @dir = dir
      path = File.join(dir, "walkthrough.mp4")
      File.binwrite(path, "x" * bytes)
      yield path
    end
  end

  def uploader(url: "https://github.com/user-attachments/assets/abc")
    FakeUploader.new(url, url ? nil : "boom", [])
  end

  def pr_copy_of(mp4) = mp4.sub(".mp4", ".pr.mp4")

  # A runner that "transcodes" by writing `bytes` bytes to the PR copy.
  def fake_transcoder(bytes, calls: nil)
    lambda do |argv|
      calls << argv if calls
      mp4 = argv.each_cons(2).find { |a, _| a == "-i" }.last.sub("/work", @dir)
      File.binwrite(pr_copy_of(mp4), "y" * bytes)
      [ "", Status.new(true) ]
    end
  end

  def target_pair(argv, gh: FakeGh.new)
    P.resolve_target(argv, gh: gh).then { |t| [ t.kind, t.number ] }
  end

  def test_splice_appends_then_replaces_idempotently
    once = P.splice("Body text", "https://u/1")
    assert_includes once, "Body text\n\n#{P::START_MARK}\n## Walkthrough\n\nhttps://u/1\n#{P::END_MARK}"
    twice = P.splice(once, "https://u/2")
    assert_equal 1, twice.scan(P::START_MARK).size
    assert_includes twice, "https://u/2"
    refute_includes twice, "https://u/1"
    assert_equal twice, P.splice(twice, "https://u/2")
  end

  def test_splice_into_empty_body
    assert_equal "#{P.section('https://u/1')}\n", P.splice(nil, "https://u/1")
  end

  def test_explicit_flags_win_over_branch_pr
    gh = FakeGh.new
    assert_equal [ :pr, "7" ], target_pair(%w[--pr 7], gh: gh)
    assert_equal [ :issue, "9" ], target_pair(%w[--issue 9], gh: gh)
    assert_empty gh.calls
  end

  def test_flag_value_must_be_digits
    [ "--pr", "--pr abc", "--issue 1;x", "--issue -3" ].each do |flags|
      assert_raises(ArgumentError) { target_pair(flags.split) }
    end
  end

  def test_none_flag_means_no_target
    assert_nil P.resolve_target(%w[--none --pr 7], gh: FakeGh.new)
  end

  def test_branch_pr_used_when_open
    gh = FakeGh.new("git branch --show-current" => [ "feat", true ], "gh pr list" => [ "42", true ])
    target = P.resolve_target([], gh: gh)
    assert_equal [ :pr, "42" ], [ target.kind, target.number ]
  end

  def test_no_open_pr_means_no_target
    gh = FakeGh.new("git branch --show-current" => [ "feat", true ], "gh pr list" => [ "", true ])
    assert_nil P.resolve_target([], gh: gh)
  end

  def test_no_target_never_uploads
    with_mp4(10) do |mp4|
      up = uploader
      out = P.publish(mp4, argv: %w[--none], gh: FakeGh.new, uploader: up)
      assert_empty up.uploaded
      assert_nil out.url
      assert_equal mp4, out.path
    end
  end

  def test_small_file_uploads_and_edits_pr_body
    with_mp4(100) do |mp4|
      up = uploader
      gh = FakeGh.new("gh pr view" => [ "old body", true ])
      out = P.publish(mp4, argv: %w[--pr 7], gh: gh, uploader: up)
      assert_equal [ mp4 ], up.uploaded
      assert_equal "https://github.com/user-attachments/assets/abc", out.url
      edit, stdin = gh.calls.last
      assert_equal %w[gh pr edit 7 --body-file -], edit
      assert_includes stdin, "old body"
      assert_includes stdin, "\nhttps://github.com/user-attachments/assets/abc\n"
    end
  end

  def test_issue_comment
    with_mp4(100) do |mp4|
      gh = FakeGh.new
      P.publish(mp4, argv: %w[--issue 3 --comment], gh: gh, uploader: uploader)
      argv, stdin = gh.calls.last
      assert_equal %w[gh issue comment 3 --body-file -], argv
      assert_includes stdin, "user-attachments/assets/abc"
    end
  end

  def test_oversize_transcodes_a_copy_and_keeps_original
    with_mp4(100) do |mp4|
      argvs = []
      small = P.shrink(mp4, runner: fake_transcoder(5, calls: argvs), max_bytes: 50)
      assert_equal pr_copy_of(mp4), small.first
      assert File.exist?(mp4)
      assert_equal 1, argvs.size
      assert_includes argvs.first, ChangeDocker::FFMPEG_IMAGE
      assert_includes argvs.first, "-crf"
    end
  end

  def test_oversize_uploads_the_copy
    with_mp4(100) do |mp4|
      up = uploader
      shrink = ->(m) { P.shrink(m, runner: fake_transcoder(1), max_bytes: 50) }
      P.publish(mp4, argv: %w[--pr 1], gh: FakeGh.new, uploader: up, shrink: shrink)
      assert_equal [ pr_copy_of(mp4) ], up.uploaded
    end
  end

  def test_ladder_exhausted_leaves_on_disk
    with_mp4(100) do |mp4|
      path, note = P.shrink(mp4, runner: fake_transcoder(90), max_bytes: 50)
      assert_nil path
      assert_match(/no transcode fit/, note)
      refute File.exist?(pr_copy_of(mp4))
    end
  end

  def test_upload_failure_degrades_without_editing
    with_mp4(100) do |mp4|
      gh = FakeGh.new
      out = P.publish(mp4, argv: %w[--pr 7], gh: gh, uploader: uploader(url: nil))
      assert_nil out.url
      assert_match(/upload skipped: boom/, out.message)
      assert_empty gh.calls
    end
  end

  def test_locate_picks_newest_render
    Dir.mktmpdir do |dir|
      a = File.join(dir, ".cache", "render", "a")
      b = File.join(dir, ".cache", "render", "b")
      [ a, b ].each { |d| FileUtils.mkdir_p(d); File.write(File.join(d, "walkthrough.mp4"), "x") }
      File.utime(Time.now - 100, Time.now - 100, File.join(a, "walkthrough.mp4"))
      assert_equal File.join(b, "walkthrough.mp4"), P.locate(dir)
    end
  end

  def test_section_lists_boards_under_the_video
    sec = P.section("https://u/1", boards: [ [ "light", "https://u/L" ], [ "dark", "https://u/D" ] ])
    assert_includes sec, "https://u/1\n\n![Flats overview, light](https://u/L)\n\n![Flats overview, dark](https://u/D)\n#{P::END_MARK}"
    twice = P.splice(P.splice("b", "https://u/1"), "https://u/2", boards: [ [ "light", "https://u/L" ] ])
    assert_equal 1, twice.scan(P::START_MARK).size
    refute_includes twice, "https://u/1"
    assert_includes twice, "![Flats overview, light](https://u/L)"
  end

  def test_publish_uploads_boards_after_video_and_attaches_them
    with_mp4(100) do |mp4|
      light = File.join(@dir, "light.png")
      dark = File.join(@dir, "dark.png")
      [ light, dark ].each { |f| File.binwrite(f, "png") }
      up = uploader
      gh = FakeGh.new("gh pr view" => [ "old", true ])
      P.publish(mp4, argv: %w[--pr 7], gh: gh, uploader: up, boards: { "light" => light, "dark" => dark })
      assert_equal [ mp4, light, dark ], up.uploaded
      assert_equal 2, gh.calls.last[1].scan("![Flats overview,").size
    end
  end

  def test_failed_board_upload_is_skipped_not_fatal
    with_mp4(100) do |mp4|
      up = Object.new
      up.define_singleton_method(:upload) do |path|
        ok = path.end_with?(".mp4")
        ChangeScreenshotUpload::Result.new(path: path, url: ok ? "https://u/v" : nil, error: ok ? nil : "nope")
      end
      gh = FakeGh.new
      out = P.publish(mp4, argv: %w[--pr 7], gh: gh, uploader: up, boards: { "light" => "/x/light.png" })
      assert_equal "https://u/v", out.url
      refute_includes gh.calls.last[1], "Flats overview"
    end
  end

  def test_locate_boards_finds_flats_for_a_slug_dir_and_a_render_path
    Dir.mktmpdir do |dir|
      %w[light dark].each do |t|
        FileUtils.mkdir_p(File.join(dir, "flats", t))
        File.write(File.join(dir, "flats", t, "overview.png"), "x")
      end
      want = { "light" => File.join(dir, "flats", "light", "overview.png"),
               "dark" => File.join(dir, "flats", "dark", "overview.png") }
      assert_equal want, P.locate_boards(dir)
      mp4 = File.join(dir, ".cache", "render", "h", "walkthrough.mp4")
      assert_equal want, P.locate_boards(mp4)
      assert_empty P.locate_boards(File.join(dir, "nowhere"))
    end
  end
end
