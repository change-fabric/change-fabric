# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "fileutils"
require "tmpdir"
require_relative "../scripts/change_flow_compiler"
require_relative "../scripts/change_suite"
require_relative "../scripts/change_visual_baseline"

# expect_visual on the host: the step's shape, the baseline path, and every way
# a verdict can fail to be a pass. The real pixel diff is in the docker test.
class ChangeVisualBaselineTest < Minitest::Test
  V = ChangeVisualBaseline

  # Signature plus IHDR: all the host reads of an image.
  def png(width = 8, height = 6) = "\x89PNG\r\n\x1a\n".b + [ 13 ].pack("N") + "IHDR" + [ width, height, 8, 6, 0, 0, 0 ].pack("NNCCCCC") + "crc!"

  def compile(spec) = ChangeFlowCompiler.new([ { "expect_visual" => spec } ]).compile.first

  def with_root
    Dir.mktmpdir do |dir|
      root = File.join(dir, "project")
      FileUtils.mkdir_p(root)
      yield root, dir
    end
  end

  def baseline_path(root) = V.path_for(root, suite: "shop", case_id: "home", name: "hero", viewport: "8x6")

  def write_baseline(root, bytes = png)
    FileUtils.mkdir_p(File.dirname(baseline_path(root)))
    File.binwrite(baseline_path(root), bytes)
  end

  def record(image: png, width: 8)
    { "ok" => true, "steps" => [ { "index" => 0, "ok" => true, "name" => "hero", "screenshot" => Base64.strict_encode64(image),
                                    "visual" => { "name" => "hero", "width" => width, "height" => 6 } } ] }
  end

  def judge(root, rec, ratio: 0.001, runner: nil, **rest)
    V.judge(rec, compiled: [ { index: 0, maxDiffRatio: ratio } ], root: root, suite: "shop", case_id: "home", runner: runner, **rest)
  end

  def counts(**data) = ->(_code) { { "total" => 48, "differing" => 0, "diff" => Base64.strict_encode64(png) }.merge(data.transform_keys(&:to_s)) }

  def status(rec) = rec["visualResults"].first["status"]

  def note(rec) = rec["visualResults"].first["note"]

  def test_the_step_compiles_with_defaults_and_is_gated_at_version_7
    step = compile("name" => "hero", "selector" => ".hero", "mask" => [ ".clock" ], "viewport" => { "width" => 800, "height" => 600 })

    assert_equal [ "expectVisual", 0.001, [ ".clock" ], { width: 800, height: 600 } ], step.values_at(:verb, :maxDiffRatio, :mask, :viewport)
    assert_equal [ 7, 8 ], [ ChangeSuiteSchema.verb_version("expect_visual"), ChangeSuiteSchema::SUITE_VERSION ]
  end

  def test_a_ratio_of_zero_is_exact_and_anything_outside_zero_to_one_is_refused
    assert_equal [ 0, 1 ], [ 0, 1 ].map { |ratio| compile("name" => "a", "max_diff_ratio" => ratio)[:maxDiffRatio] }
    [ 100, 1.5, -0.1, "0.1", true, Float::NAN, Float::INFINITY ].each do |bad|
      error = assert_raises(ChangeFlowCompiler::Error, bad.inspect) { compile("name" => "a", "max_diff_ratio" => bad) }

      assert_match(/fraction from 0 to 1/, error.message)
    end
  end

  def test_names_masks_and_keys_are_checked
    [ "../x", "a/b", ".hidden", "", "a b", "x" * 65 ].each { |bad| assert_raises(ChangeFlowCompiler::Error, bad.inspect) { compile("name" => bad) } }
    [ ".clock", [ "text=Now" ], [ " " ] ].each { |mask| assert_raises(ChangeFlowCompiler::Error) { compile("name" => "a", "mask" => mask) } }
    assert_raises(ChangeFlowCompiler::Error) { compile("name" => "a", "threshold" => 1) }
  end

  def test_hostile_ids_stay_under_the_visual_dir
    with_root do |root|
      path = V.path_for(root, suite: "../../etc", case_id: "..", name: "hero", viewport: "1x1")

      assert path.start_with?("#{File.join(File.realpath(root), '.cf', 'visual')}/")
      refute_includes path.delete_prefix(File.realpath(root)).split("/"), ".."
      assert_raises(V::Unsafe) { V.path_for(root, suite: "s", case_id: "c", name: "../x", viewport: "1x1") }
    end
  end

  def test_a_symlinked_dir_or_file_is_refused_and_the_step_is_blocked
    with_root do |root, dir|
      FileUtils.mkdir_p([ File.join(dir, "outside"), File.join(root, ".cf") ])
      File.binwrite(File.join(dir, "outside", "hero-8x6.png"), png)
      File.symlink(File.join(dir, "outside"), File.join(root, ".cf", "visual"))

      assert_match(/symlink/, assert_raises(V::Unsafe) { baseline_path(root) }.message)
      File.delete(File.join(root, ".cf", "visual"))
      FileUtils.mkdir_p(File.join(root, ".cf", "visual", "shop", "home"))
      File.symlink(File.join(dir, "outside", "hero-8x6.png"), File.join(root, ".cf", "visual", "shop", "home", "hero-8x6.png"))
      rec = judge(root, record, runner: counts)

      assert_equal "blocked", status(rec)
      assert_match(/refused: .*symlink/, note(rec))
    end
  end

  def test_reading_nothing_or_a_directory
    with_root do |root|
      assert_nil V.read(baseline_path(root))
      FileUtils.mkdir_p(baseline_path(root))
      assert_raises(V::Unsafe) { V.read(baseline_path(root)) }
    end
  end

  def test_no_baseline_is_blocked_with_a_promote_command_and_never_written
    with_root do |root, dir|
      rec = judge(root, record, evidence_dir: dir)

      assert_equal "blocked", status(rec)
      refute rec["ok"]
      assert_match(%r{\Ablocked_precondition: no baseline at \.cf/visual/shop/home/hero-8x6\.png}, rec["steps"].first["error"])
      assert_match(%r{\Amkdir -p \S+ && cp \S+/shot-0001-hero\.png \S+/hero-8x6\.png\z}, rec["visualResults"].first["promote"])
      refute File.exist?(File.join(root, ".cf")), "a missing baseline is never created"
    end
  end

  def test_ratios_zero_and_one_and_the_images_kept_on_a_pass
    with_root do |root, dir|
      write_baseline(root)
      passed = judge(root, record, ratio: 0.1, runner: counts(differing: 4), evidence_dir: dir)

      assert passed["ok"]
      assert_equal %w[actual baseline diff], passed["visualResults"].first["files"].keys.sort
      assert File.exist?(File.join(dir, passed["visualResults"].first["files"]["diff"]))
      verdicts = [ [ 0, 1 ], [ 0, 0 ], [ 1, 48 ] ].map { |ratio, differing| status(judge(root, record, ratio: ratio, runner: counts(differing: differing))) }

      assert_equal %w[fail pass pass], verdicts
      assert_match(/\Avisual diff: 12 of 48 pixels differ \(25.0%\)/, judge(root, record, runner: counts(differing: 12))["steps"].first["error"])
    end
  end

  def test_a_size_mismatch_fails_before_any_ratio
    with_root do |root|
      write_baseline(root)
      rec = judge(root, record, ratio: 1, runner: ->(_code) { { "sizeMismatch" => true, "baseline" => [ 8, 6 ], "actual" => [ 8, 9 ] } })

      assert_equal [ "fail", "size mismatch: baseline 8x6, actual 8x9" ], rec["visualResults"].first.values_at("status", "note")
    end
  end

  def test_a_zero_pixel_image_nonsense_counts_or_a_missing_container_is_blocked_never_a_pass
    with_root do |root|
      write_baseline(root)
      [ { "total" => 0, "differing" => 0 }, { "total" => 48, "differing" => 99 }, { "total" => 48, "differing" => -1 },
        { "total" => "NaN", "differing" => 0 }, nil ].each do |data|
        rec = judge(root, record, ratio: 1, runner: ->(_code) { data })

        assert_equal "blocked", status(rec), data.inspect
        refute rec["ok"], data.inspect
      end
      assert_match(/unavailable/, note(judge(root, record)))
      assert_match(/connection refused/, note(judge(root, record, runner: ->(_code) { raise "connection refused" })))
      assert_match(/no image/, note(judge(root, record(image: png(0, 0)), runner: counts)))
    end
  end

  def test_an_unreadable_baseline_a_bad_viewport_or_a_missing_spec_is_blocked_and_secrets_are_masked
    with_root do |root|
      write_baseline(root, "GIF89a not a png, padded to read")

      assert_match(/not a PNG/, note(judge(root, record, runner: counts)))
      assert_equal "blocked", status(judge(root, record(width: "wide")))
      assert_equal "blocked", status(V.judge(record, compiled: [], root: root, suite: "shop", case_id: "home"))
      named = record
      named["steps"].first["visual"]["name"] = "hunter2pw"
      rec = V.judge(named, compiled: [ { index: 0, maxDiffRatio: 1 } ], root: root, suite: "shop", case_id: "home", secrets: [ "hunter2pw" ])

      refute_includes [ rec["visualResults"], rec["steps"].first["error"] ].to_s, "hunter2pw"
    end
  end
end
