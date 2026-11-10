# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/walkthrough_diagram"
require_relative "../scripts/walkthrough_storyboard"
require_relative "support/lane_spec_generator"
require_relative "support/lane_invariants"

# Seeded generated swimlane specs in the pinned browserless container, each
# held to LaneInvariants at a few moments: the opening frame, the middle of
# a travel, and after the last result lands. Seeds 1..24 run every time;
# CF_LANES_SEEDS=500 sweeps 1..500. A failure starts with seed=<n> and the
# spec JSON, so CF_LANES_SEEDS=<n> (or the seed alone) reproduces it.
class WalkthroughDiagramLanesGeneratedTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/walkthrough/diagram-swimlanes", __dir__)
  DEFAULT_SEEDS = 24
  # Specs loaded per browserless session.
  BATCH = 24

  def seeds = (1..Integer(ENV.fetch("CF_LANES_SEEDS", DEFAULT_SEEDS)))

  def test_generated_specs_hold_the_lane_invariants
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |root|
      FileUtils.cp_r("#{FIXTURE}/.", root)
      board = WalkthroughStoryboard.load(File.join(root, "storyboard.json"))
      scene = board["scenes"].first
      cases = seeds.map do |seed|
        gen = LaneSpecGenerator.new(seed)
        scene["diagram"] = gen.spec
        [ seed, gen.spec, WalkthroughDiagram.screen(scene, root: root, board: board), times(gen.spec) ]
      end
      cases.each_slice(BATCH) do |batch|
        probes = ChangeDocker.with_browserless(network: nil) do |session|
          batch.map { |_, _, html, t| session.run_function(LaneInvariants.probe_js(html, board["viewport"], t)) }
        end
        batch.zip(probes).each do |(seed, spec, _, _), probe|
          LaneInvariants.assert_lane_invariants(self, probe, spec, board["viewport"], tag: "seed=#{seed} spec=#{JSON.generate(spec)}")
        end
      end
    end
  end

  private

  # The opening frame, a moment after any highlight lands, the middle of
  # each travel, and after every result has landed.
  def times(spec)
    travels = spec["steps"].select { |s| s["op"] == "travel" }
    mids = travels.map { |s| s["t_ms"] + (s["duration"] / 2) }
    ([ 0, 500 ] + mids + [ LaneSpecGenerator::DURATION_MS - 100 ]).uniq.sort
  end
end
