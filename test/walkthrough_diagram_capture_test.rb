# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/prototype_capture"
require_relative "../scripts/walkthrough_diagram"
require_relative "../scripts/walkthrough_storyboard"

# A React Flow diagram screen renders deterministically under the controlled
# clock: two captures in the pinned browserless container give identical
# frames, the page throws nothing, nothing leaves the page, the UX lint is
# clean, and the scripted steps actually change the picture.
class WalkthroughDiagramCaptureTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/walkthrough/diagram", __dir__)
  RUNTIME = File.expand_path("../scripts/vendor/xyflow/cf_diagram_runtime.js", __dir__)
  DURATION_MS = 2000
  VIEWPORT = { "w" => 1280, "h" => 720, "dpr" => 1 }.freeze

  # Passes run_function through and keeps every raw result, so the test sees
  # pageErrors and blockedRequests that capture itself does not return.
  class Recorder
    attr_reader :results

    def initialize(session)
      @session = session
      @results = []
    end

    def run_function(code, **opts)
      @session.run_function(code, **opts).tap { |r| @results << r }
    end

    def alive? = @session.alive?
  end

  def test_two_captures_produce_identical_frames
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |root|
      html = screen
      ChangeDocker.with_browserless(network: nil) do |session|
        runs = 2.times.map { |n| capture(Recorder.new(session), html, File.join(root, "run-#{n}")) }
        a, b = runs.map { |r| r[:hashes] }
        assert_equal PrototypeCapture.frame_count(DURATION_MS), a.size
        assert_equal a, b, "diagram frames differ between captures"
        refute_equal a.first, a.last, "the scripted steps change the picture"
        runs.each do |run|
          assert_empty run[:errors], "page errors: #{run[:errors].inspect}"
          assert_empty run[:blocked], "blocked requests: #{run[:blocked].inspect}"
          assert_empty run[:findings], "UX lint findings: #{run[:findings].inspect}"
        end
      end
    end
  end

  # The whole path an author takes: a storyboard diagram block, the
  # generator, the storyboard's frames prep, inline_screen, and a capture.
  def test_storyboard_diagram_scene_generates_and_captures
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |root|
      FileUtils.cp_r("#{File.expand_path('fixtures/walkthrough/architecture', __dir__)}/.", root)
      board = WalkthroughStoryboard.load(File.join(root, "storyboard.json"))
      WalkthroughDiagram.write_screens(board, root)
      assert_empty WalkthroughStoryboard.validate(board, root: root)
      scene = board["scenes"].first
      prep = PrototypeCapture.prepare(board, scene, root)
      ChangeDocker.with_browserless(network: nil) do |session|
        recorder = Recorder.new(session)
        PrototypeCapture.capture(session: recorder, html: PrototypeCapture.inline_screen(prep[:html_path], root: root),
                                 interactions: [], duration_ms: PrototypeCapture.scene_duration(scene), out_dir: prep[:out_dir],
                                 state: prep[:state], prng_seed: prep[:prng_seed], viewport: board["viewport"], label: scene["id"])
        frames = Dir[File.join(prep[:out_dir], "*.png")].sort
        assert_equal PrototypeCapture.frame_count(PrototypeCapture.scene_duration(scene)), frames.size
        refute_equal Digest::SHA256.file(frames.first).hexdigest, Digest::SHA256.file(frames.last).hexdigest
        assert_empty recorder.results.flat_map { |r| Array(r["pageErrors"]) }
        assert_empty recorder.results.flat_map { |r| Array(r["blockedRequests"]) }
        assert_empty JSON.parse(File.read(File.join(prep[:out_dir], PrototypeUxLint::REPORT)))["findings"]
      end
    end
  end

  def test_a_screen_that_never_gets_ready_fails_loudly
    skip "docker not available" unless ChangeDocker.available?

    html = "<html><head></head><body><script>window.__cfDiagramReady = false;</script></body></html>"
    stub_const(:DIAGRAM_READY_TIMEOUT_MS, 500) do
      Dir.mktmpdir do |root|
        ChangeDocker.with_browserless(network: nil) do |session|
          err = assert_raises(PrototypeCapture::UnsupportedContentError) do
            PrototypeCapture.capture(session: session, html: html, interactions: [], duration_ms: 100, out_dir: root,
                                     state: nil, prng_seed: 1, viewport: VIEWPORT, label: "stuck")
          end
          assert_match(/never set __cfDiagramReady/, err.message)
        end
      end
    end
  end

  private

  def stub_const(name, value)
    old = PrototypeCapture.const_get(name)
    PrototypeCapture.send(:remove_const, name)
    PrototypeCapture.const_set(name, value)
    yield
  ensure
    PrototypeCapture.send(:remove_const, name)
    PrototypeCapture.const_set(name, old)
  end

  # Inlines the bundle and runtime by hand, as the Phase 3 generator will.
  # inline_screen is not used: it scans inlined script text for src/srcset
  # attributes and trips on string literals inside the React DOM bundle.
  def screen
    html = File.read(File.join(FIXTURE, "screen.html"))
    { "xyflow.js" => WalkthroughDiagram::XYFLOW_BUNDLE, "runtime.js" => RUNTIME }.each do |src, file|
      body = File.read(file).gsub("</script", "<\\/script")
      html = html.sub(%(<script src="#{src}"></script>)) { "<script>#{body}</script>" }
    end
    html
  end

  def capture(recorder, html, out)
    PrototypeCapture.capture(session: recorder, html: html, interactions: [], duration_ms: DURATION_MS, out_dir: out,
                             state: nil, prng_seed: 1, viewport: VIEWPORT, label: "diagram")
    report = JSON.parse(File.read(File.join(out, PrototypeUxLint::REPORT)))
    { hashes: Dir[File.join(out, "*.png")].sort.map { |f| Digest::SHA256.file(f).hexdigest },
      errors: recorder.results.flat_map { |r| Array(r["pageErrors"]) },
      blocked: recorder.results.flat_map { |r| Array(r["blockedRequests"]) },
      findings: report["findings"] }
  end
end
