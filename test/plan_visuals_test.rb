# frozen_string_literal: true

require_relative "test_helpers"
require "fileutils"
require_relative "#{File.expand_path('../scripts', __dir__)}/plan_check"
require_relative "../scripts/plan_visuals"
require "open3"
require "rbconfig"
require "tmpdir"

class PlanVisualsTest < Minitest::Test
  include SkillTempHome
  # Built from a codepoint so this file never carries the glyph it tests for.
  EM = [ 0x2014 ].pack("U")
  GOOD_SVG = '<svg xmlns="http://www.w3.org/2000/svg" data-diagram-type="flow"><title>Flow</title></svg>'
  VISUALS = "## Visuals\n\n- diagrams/flow.svg, flow, the phase order.\n"

  def with_plan(plan:, files: {})
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "plan.md"), plan)
      files.each do |rel, body|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      lines = []
      ok = PlanCheck.check_visuals(dir, lines)
      yield ok, lines
    end
  end

  def test_no_diagrams_and_no_section_skips_the_check
    with_plan(plan: "## Phases\n\nP1.\n") do |ok, lines|
      assert ok
      assert_empty lines
    end
  end

  def test_a_listed_svg_that_is_missing_fails
    with_plan(plan: VISUALS) do |ok, lines|
      refute ok
      assert_includes lines, "visuals: diagrams/flow.svg named in ## Visuals is MISSING or empty"
    end
  end

  def test_an_svg_with_no_type_attribute_fails
    with_plan(plan: VISUALS, files: { "diagrams/flow.svg" => "<svg><title>x</title></svg>" }) do |ok, lines|
      refute ok
      assert_includes lines, "diagrams/flow.svg: MISSING data-diagram-type or data-chart-type"
    end
  end

  def test_an_em_dash_in_an_svg_fails
    svg = GOOD_SVG.sub("Flow</title>", "Flow #{EM} x</title>")
    with_plan(plan: VISUALS, files: { "diagrams/flow.svg" => svg }) do |ok, lines|
      refute ok
      assert_includes lines, "diagrams/flow.svg: contains a banned AI-slop glyph"
    end
  end

  def test_a_home_path_in_an_svg_fails
    svg = GOOD_SVG.sub("Flow</title>", "#{File.join(Dir.home, 'x')}</title>")
    with_plan(plan: VISUALS, files: { "diagrams/flow.svg" => svg }) do |ok, lines|
      refute ok
      assert(lines.any? { |l| l.start_with?("diagrams/flow.svg: contains a literal absolute home path") })
    end
  end

  def test_a_roast_round_without_its_response_fails
    files = { "diagrams/flow.svg" => GOOD_SVG, "roast/round-1.json" => "{}" }
    with_plan(plan: VISUALS, files:) do |ok, lines|
      refute ok
      assert_includes lines, "roast/round-1.json: MISSING round-1.response.json"
    end
  end

  def test_a_complete_set_passes
    chart = '<svg data-chart-type="bar"><title>Cost</title></svg>'
    files = { "diagrams/flow.svg" => GOOD_SVG, "diagrams/cost.svg" => chart,
              "roast/round-1.json" => "{}", "roast/round-1.response.json" => "{}" }
    with_plan(plan: "#{VISUALS}- diagrams/cost.svg, bar, cost.\n\n## Roast\n\nOne round.\n", files:) do |ok, lines|
      assert ok, lines.join("\n")
      assert_includes lines, "visuals: diagrams/cost.svg present"
      assert_includes lines, "roast/round-1.json: response present"
    end
  end

  def test_a_section_with_no_visuals_passes
    with_plan(plan: "## Visuals\n\nNone (single-PR, single-subsystem plan).\n") do |ok, _lines|
      assert ok
    end
  end
  ROAST_STEP = File.read(File.expand_path("../skills/plan/SKILL.md", __dir__))[/^7b\. \*\*Roast\.\*\*.*?(?=^\d+\. \*\*)/m]

  def test_roast_step_passes_the_required_brief
    assert_includes ROAST_STEP, "--brief <plan_dir>/goal.md"
  end

  def test_roast_step_writes_a_response_file_every_round
    assert_includes ROAST_STEP, "roast/round-N.response.json"
    assert_match(/empty response list/, ROAST_STEP)
  end

  def test_roast_step_re_renders_visuals_before_round_two
    assert_match(/re-render both\s+themes with `diagram_render.rb`/, ROAST_STEP)
  end
end

# plan_visuals.rb with every collaborator faked: gh answers from a table and
# records its calls, and the uploader never touches the network.
class PlanVisualsScriptTest < Minitest::Test
  PV = PlanVisuals
  SCRIPT = File.expand_path("../scripts/plan_visuals.rb", __dir__)

  class FakeGh
    attr_reader :calls

    def initialize(table = {})
      @table = table
      @calls = []
    end

    def run(*argv, stdin: nil)
      @calls << argv
      key = @table.keys.find { |k| argv.join(" ").start_with?(k) }
      key ? @table[key] : [ "", true ]
    end

    def edits = @calls.select { |c| c[0, 3] == %w[gh pr edit] }
  end

  class FakeUploader
    attr_reader :paths

    def initialize(fail_at: nil)
      @fail_at = fail_at
      @paths = []
    end

    def upload_all(paths)
      paths.each_with_index.map do |path, i|
        @paths << path
        ok = @fail_at.nil? || i < @fail_at
        ChangeScreenshotUpload::Result.new(path: path, url: ok ? "https://u/#{File.basename(path)}" : nil,
                                           error: ok ? nil : "HTTP 500")
      end
    end

    def degradation_reason = "HTTP 500"
  end

  WORKFLOW = <<~JS
    export const meta = { name: "demo", phases: [ { title: "Build the widget parser" }, { title: "Wire the widget output" } ] }
    phase("Build the widget parser")
    phase("Wire the widget output")
  JS

  def svg(type, title, label, kind: "diagram")
    %(<svg data-#{kind}-type="#{type}"><title>#{title}</title><desc>About it</desc><text>#{label}</text></svg>)
  end

  def with_plan(manifest: true)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "diagrams"))
      File.write(File.join(dir, "workflow.js"), WORKFLOW)
      File.write(File.join(dir, "plan.md"), <<~MD)
        # Demo

        Touches lib/widget.rb.

        ## Visuals

        - diagrams/flow.svg - flow - overall (phases: all)
        - diagrams/arch.svg - architecture - layers (phases: 2)
        - diagrams/parse.svg - sequence - parser step (phases: 1)
        - diagrams/wire.svg - sequence - output step (phases: 2)
        - diagrams/plan.svg - timeline - schedule (phases: 1,2)
      MD
      { "flow" => svg("flow", "Flow", "lib/widget.rb"), "arch" => svg("architecture", "Arch", "layers"),
        "parse" => svg("sequence", "Parse", "src/parser.rb"), "wire" => svg("sequence", "Wire", "out/"),
        "plan" => svg("timeline", "Plan", "two phases") }.each do |name, body|
        File.write(File.join(dir, "diagrams", "#{name}.svg"), body)
        File.write(File.join(dir, "diagrams", "#{name}-light.png"), "L")
        File.write(File.join(dir, "diagrams", "#{name}-dark.png"), "D")
      end
      write_manifest(dir) if manifest
      yield dir
    end
  end

  def write_manifest(dir, count: 2)
    data = { version: 1, plan_sha256: PV.plan_digest(File.join(dir, "plan.md")), workflow_phase_count: count, visuals: {} }
    File.write(File.join(dir, "diagrams", "manifest.json"), JSON.generate(data))
  end

  def pr_gh(files: [ "lib/widget.rb", "src/parser.rb" ], title: "Build the widget parser", body: "Intro")
    FakeGh.new(
      "gh pr view 7 --json files" => [ JSON.generate(files: files.map { |f| { path: f } }, title: title, headRefName: "widget-p1"), true ],
      "gh pr view 7 --json body" => [ body, true ]
    )
  end

  def check(dir, gh, phase: 1)
    facts = PV.pr_facts(gh, 7, nil)
    PV.select(dir, phase: phase)[:visuals].to_h do |v|
      r = PV.check_visual(v, plan_dir: dir, pr: facts, phase: phase, manifest: PV.manifest(dir))
      [ v.name, r ]
    end
  end

  def test_phase_one_gets_all_architecture_timeline_and_own_tags
    with_plan { |dir| assert_equal %w[flow arch parse plan], PV.select(dir, phase: 1)[:visuals].map(&:name) }
  end

  def test_phase_two_gets_only_its_own_non_first_pr_tags
    with_plan do |dir|
      picked = PV.select(dir, phase: 2)
      assert_equal %w[wire], picked[:visuals].map(&:name)
      refute picked[:link_back]
    end
  end

  def test_later_phase_with_nothing_tagged_links_back
    with_plan { |dir| assert PV.select(dir, phase: 3)[:link_back] }
  end

  def test_untagged_line_counts_as_all
    with_plan do |dir|
      File.write(File.join(dir, "plan.md"), "# P\n\n## Visuals\n\n- diagrams/wire.svg - sequence - old\n")
      assert_equal "all", PV.visuals(dir).first.phases
    end
  end

  def test_all_match_with_paths_title_and_digest
    with_plan do |dir|
      verdicts = check(dir, pr_gh).transform_values { |r| r[:verdict] }
      assert_equal({ "flow" => "match", "arch" => "match", "parse" => "match", "plan" => "match" }, verdicts)
    end
  end

  def test_unknown_path_label_is_drift
    with_plan do |dir|
      result = check(dir, pr_gh(files: [ "lib/widget.rb" ]))["parse"]
      assert_equal "drift", result[:verdict]
      assert_match "src/parser.rb", result[:reasons].join
    end
  end

  def test_slash_word_pairs_are_not_paths
    assert_empty "match/drift and CI/CD".scan(PV::PATH_LIKE)
  end

  def test_low_title_overlap_is_inconclusive_not_drift
    with_plan do |dir|
      result = check(dir, pr_gh(title: "Unrelated thing"))["flow"]
      assert_equal "inconclusive", result[:verdict]
    end
  end

  def test_plan_edit_after_drawing_is_drift_but_visuals_edits_are_not
    with_plan do |dir|
      plan = File.join(dir, "plan.md")
      File.write(plan, "#{File.read(plan)}\nRoast note appended to visuals.\n")
      assert_equal "match", check(dir, pr_gh)["flow"][:verdict]
      File.write(plan, File.read(plan).sub("Touches", "Now touches"))
      assert_equal "drift", check(dir, pr_gh)["flow"][:verdict]
    end
  end

  def test_manifest_absent_is_inconclusive_except_timeline
    with_plan(manifest: false) do |dir|
      results = check(dir, pr_gh)
      assert_equal "inconclusive", results["flow"][:verdict]
      assert_equal "drift", results["plan"][:verdict]
    end
  end

  def test_timeline_phase_count_change_is_drift
    with_plan do |dir|
      write_manifest(dir, count: 3)
      results = check(dir, pr_gh)
      assert_equal "drift", results["plan"][:verdict]
      assert_equal "match", results["flow"][:verdict]
    end
  end

  def test_check_cli_exit_codes
    with_plan do |dir|
      assert_equal 0, PV::CLI.run([ "check", dir, "--pr", "7", "--phase", "1" ], out: StringIO.new, gh: pr_gh)
      assert_equal 1, PV::CLI.run([ "check", dir, "--pr", "7", "--phase", "1" ], out: StringIO.new, gh: pr_gh(files: []))
      assert_equal 2, PV::CLI.run([ "check", dir, "--pr", "7", "--phase", "2" ], out: StringIO.new, gh: pr_gh(files: [ "out/a.rb" ], title: "zzz"))
    end
  end

  def test_compose_wraps_picture_embeds_in_markers
    with_plan do |dir|
      visuals = PV.select(dir, phase: 2)[:visuals]
      out = PV.compose(visuals, urls: { "wire" => { "light" => "L1", "dark" => "D1" } }, hash: "abc",
                                omits: { "x" => "redraw failed (lint)" })
      assert out.start_with?("<!-- cf:plan-visuals sha=abc -->\n## Plan visuals")
      assert_includes out, %(<picture><source media="(prefers-color-scheme: dark)" srcset="D1"><img src="L1" alt="Wire"></picture>)
      assert_includes out, "x omitted: redraw failed (lint)"
      assert out.end_with?(PV::END_MARK)
    end
  end

  def test_compose_link_back
    out = PV.compose([], urls: {}, hash: "h", first_pr: "5")
    assert_equal "<!-- cf:plan-visuals sha=h -->\nPlan visuals: see #5.\n#{PV::END_MARK}", out
  end

  def test_post_uploads_both_pngs_and_edits_body
    with_plan do |dir|
      gh = pr_gh
      up = FakeUploader.new
      outcome = PV::Poster.new(dir, pr: 7, gh: gh, uploader: up).post(phase: 2)
      assert_equal 0, outcome.code
      assert_equal %w[wire-light.png wire-dark.png], up.paths.map { |p| File.basename(p) }
      assert_equal 1, gh.edits.size
    end
  end

  def test_idempotent_post_makes_no_upload
    with_plan do |dir|
      hash = PV.section_hash(PV.select(dir, phase: 2)[:visuals])
      gh = pr_gh(body: "Intro\n\n#{PV::START_PREFIX}#{hash} -->\nold\n#{PV::END_MARK}")
      up = FakeUploader.new
      outcome = PV::Poster.new(dir, pr: 7, gh: gh, uploader: up).post(phase: 2)
      assert_equal [ "unchanged" ], outcome.lines
      assert_empty up.paths
      assert_empty gh.edits
    end
  end

  def test_repo_reaches_every_pr_command
    with_plan do |dir|
      gh = FakeGh.new("gh pr view 7 --json mergeStateStatus" => [ JSON.generate(mergeStateStatus: "CLEAN", statusCheckRollup: []), true ])
      PV::Poster.new(dir, pr: 7, gh: gh, uploader: FakeUploader.new, repo: "o/r").post(phase: 2, require_settled: true)
      pr_calls = gh.calls.select { |c| c[0, 2] == %w[gh pr] }
      assert_equal 3, pr_calls.size
      assert(pr_calls.all? { |c| c.each_cons(2).include?([ "--repo", "o/r" ]) })
    end
  end

  def test_rendering_a_missing_png_reposts_the_visual
    with_plan do |dir|
      File.delete(File.join(dir, "diagrams", "wire-dark.png"))
      assert_equal [ "posted 0 visual(s)" ], PV::Poster.new(dir, pr: 7, gh: pr_gh, uploader: FakeUploader.new).post(phase: 2).lines
      first = PV.section_hash(PV.select(dir, phase: 2)[:visuals], unrendered: [ "wire" ])
      File.write(File.join(dir, "diagrams", "wire-dark.png"), "D")
      up = FakeUploader.new
      again = pr_gh(body: "Intro\n\n#{PV::START_PREFIX}#{first} -->\nold\n#{PV::END_MARK}")
      outcome = PV::Poster.new(dir, pr: 7, gh: again, uploader: up).post(phase: 2)
      assert_equal "posted 1 visual(s)", outcome.lines.first
      assert_equal %w[wire-light.png wire-dark.png], up.paths.map { |p| File.basename(p) }
    end
  end

  def test_phase_count_reads_declared_phases_not_call_sites
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "workflow.js"), <<~JS)
        export const meta = { phases: [ { title: "A" }, { title: "B" }, { title: "C" }, { title: "Verify" } ] }
        // phase(...) runs once per spec below
        for (const spec of PHASES) { phase(spec.title) }
        phase("Verify")
      JS
      assert_equal 4, PV.workflow_phase_count(dir)
    end
  end

  def test_one_failed_upload_means_no_edit
    with_plan do |dir|
      gh = pr_gh
      outcome = PV::Poster.new(dir, pr: 7, gh: gh, uploader: FakeUploader.new(fail_at: 1)).post(phase: 2)
      assert_equal 3, outcome.code
      assert_empty gh.edits
    end
  end

  def test_replacement_between_markers_leaves_demo_untouched
    demo = "<!-- cf:screenshot -->\n## Demo\n\nshots\n<!-- /cf:screenshot -->"
    body = "Intro\n\n#{PV::START_PREFIX}0dd -->\nstale\n#{PV::END_MARK}\n\n#{demo}"
    spliced = PV.splice(body, "#{PV::START_PREFIX}abc -->\nfresh\n#{PV::END_MARK}")
    assert_includes spliced, demo
    assert_includes spliced, "fresh"
    refute_includes spliced, "stale"
    assert_equal "Intro\n\nnew", PV.splice("Intro\n", "new")
  end

  def test_require_settled_refuses_unless_clean_and_green
    with_plan do |dir|
      dirty = FakeGh.new("gh pr view 7 --json mergeStateStatus" => [ JSON.generate(mergeStateStatus: "BLOCKED", statusCheckRollup: []), true ])
      up = FakeUploader.new
      assert_equal 4, PV::Poster.new(dir, pr: 7, gh: dirty, uploader: up).post(require_settled: true).code
      red = FakeGh.new("gh pr view 7 --json mergeStateStatus" => [ JSON.generate(mergeStateStatus: "CLEAN", statusCheckRollup: [ { conclusion: "FAILURE" } ]), true ])
      assert_equal 4, PV::Poster.new(dir, pr: 7, gh: red, uploader: up).post(require_settled: true).code
      assert_empty up.paths
    end
  end

  def test_dry_run_uploads_nothing
    with_plan do |dir|
      gh = pr_gh
      up = FakeUploader.new
      outcome = PV::Poster.new(dir, pr: 7, gh: gh, uploader: up).post(dry_run: true)
      assert_equal "would post", outcome.lines.first
      assert_empty up.paths
      assert_empty gh.edits
    end
  end

  # End to end through a stub gh on PATH: the CLI refuses an unsettled PR
  # before any upload is attempted, so the real uploader is never reached.
  def test_cli_require_settled_with_stub_gh_on_path
    with_plan do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "gh"), "#!/bin/sh\necho '{\"mergeStateStatus\":\"BEHIND\",\"statusCheckRollup\":[]}'\n")
      File.chmod(0o755, File.join(bin, "gh"))
      env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}" }
      out, status = Open3.capture2e(env, RbConfig.ruby, SCRIPT, "post", dir, "--pr", "7", "--require-settled")
      assert_equal 4, status.exitstatus
      assert_match "BEHIND", out
    end
  end
end
