# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"

# Skills name roles ({{model:<role>}}), never tiers. Every tier literal under
# skills/ is a failure; the one marker left, `model-roles: allow <reason>`, is
# limited to MARKER_EXCEPTIONS. Workflow JS is also linted for spawns that name
# no model, since the advisory hook (scripts/model_role_guard.rb) cannot see
# agent() calls made by the Workflow runtime.
class ModelRolesLintTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  TIER = /\b(opus|sonnet|haiku)\b/i
  MARKER = /model-roles: allow(?<reason>.*)/
  # file => why a marker may stay. Adding to it is a reviewed code change.
  MARKER_EXCEPTIONS = { "skills/walkthrough/reference/storyboard-schema.md" => "Opus names the audio codec" }.freeze
  MODEL_OPTION = "model: {{model-js:"
  # A spread of a constant that itself holds `model: {{model-js:<role>}}`
  # (file => constants), checked to exist so the spread cannot go stale.
  MODEL_SPREADS = { "skills/drive/reference/workflow.js" => %w[DEFAULT_LANE_MODEL] }.freeze

  # [[path, line, text]] of tier literals, and [[path, line, reason]] of markers.
  def self.scan(root = ROOT)
    hits = []
    markers = []
    Dir.glob(File.join(root, "skills", "**", "*.{md,js}")).sort.each do |file|
      path = file.delete_prefix("#{root}/")
      File.foreach(file, encoding: "UTF-8").each_with_index do |raw, index|
        line = raw.scrub.strip
        if (marker = line.match(MARKER))
          markers << [ path, index + 1, marker[:reason].strip ]
        elsif line.match?(TIER)
          hits << [ path, index + 1, line ]
        end
      end
    end
    [ hits, markers ]
  end

  # [[path, line, call]] of every agent( call in skills/**/*.js that carries no
  # model option. Comment lines are skipped; arguments are read by paren depth.
  def self.unmodeled_spawns(root = ROOT)
    found = []
    Dir.glob(File.join(root, "skills", "**", "*.js")).sort.each do |file|
      path = file.delete_prefix("#{root}/")
      source = File.read(file, encoding: "UTF-8").scrub
      source.scan(/\bagent\(/) do
        match = Regexp.last_match
        before = source[source.rindex("\n", match.begin(0)).to_i...match.begin(0)]
        next if before.include?("//") || before.include?("function ")

        call = call_text(source, match.begin(0))
        found << [ path, source[0...match.begin(0)].count("\n") + 1, call ] unless modeled?(path, source, call)
      end
    end
    found
  end

  def self.call_text(source, start)
    depth = 0
    opened = false
    source[start..].each_char.with_index do |char, offset|
      depth += 1 if char == "("
      depth -= 1 if char == ")"
      opened ||= depth.positive?
      return source[start, offset + 1] if opened && depth.zero?
    end
    source[start..]
  end

  def self.modeled?(path, source, call)
    return true if call.include?(MODEL_OPTION)

    MODEL_SPREADS.fetch(path, []).any? do |name|
      call.include?("?? #{name}") && source.include?("const #{name} = { #{MODEL_OPTION}")
    end
  end

  def test_no_tier_literal_in_skills
    hits, = self.class.scan
    assert_empty hits.map { |path, line, text| "#{path}:#{line}: #{text}" },
                 "skills name roles ({{model:<role>}} / model: {{model-js:<role>}}), not tiers. " \
                 "Use a role, or add `model-roles: allow <reason>` to the line and a MARKER_EXCEPTIONS entry."
  end

  def test_every_marker_carries_a_reason
    _, markers = self.class.scan
    bare = markers.select { |_, _, reason| reason.empty? }
    assert_empty bare.map { |path, line, _| "#{path}:#{line}" }, "model-roles: allow needs a reason"
  end

  def test_markers_are_limited_to_the_exception_list
    _, markers = self.class.scan
    stray = markers.reject { |path, _, _| MARKER_EXCEPTIONS.key?(path) }
    assert_empty stray.map { |path, line, _| "#{path}:#{line}" }, "a marker needs a MARKER_EXCEPTIONS entry"
  end

  def test_every_marker_exception_still_has_a_marker
    _, markers = self.class.scan
    unused = MARKER_EXCEPTIONS.keys - markers.map(&:first)
    assert_empty unused, "these MARKER_EXCEPTIONS entries have no marker left; delete them"
  end

  def test_every_workflow_agent_call_names_a_model
    assert_empty self.class.unmodeled_spawns.map { |path, line, call| "#{path}:#{line}: #{call[0, 60].inspect}" },
                 "an agent( call without `model: {{model-js:<role>}}` inherits the orchestrator tier"
  end

  def test_the_spawn_scan_flags_a_missing_model_and_skips_comments
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "skills", "x"))
      File.write(File.join(root, "skills", "x", "w.js"), <<~JS)
        // agent("commented out")
        const a = await agent("bare", { label: "a" })
        const b = await agent("ok", { model: {{model-js:worker}} })
      JS
      found = self.class.unmodeled_spawns(root)

      assert_equal [ [ "skills/x/w.js", 2 ] ], found.map { |path, line, _| [ path, line ] }
    end
  end
end
