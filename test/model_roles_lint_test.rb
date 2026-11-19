# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "yaml"

# Skills name roles ({{model:<role>}}), never tiers. Phase 1 seeds the allowlist
# with every literal that exists today; each shard PR deletes the entries it
# converts, and the last phase deletes the file. Entries are keyed by file plus
# the exact matched line, so a new literal fails even when another literal in
# the same file was removed in the same change, and a stale entry fails too.
class ModelRolesLintTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ALLOWLIST = File.join(__dir__, "fixtures", "model_roles_allowlist.yml")
  TIER = /\b(opus|sonnet|haiku)\b/i
  MARKER = /model-roles: allow(?<reason>.*)/
  # file => why a marker may stay once the allowlist is gone (Phase 6).
  MARKER_EXCEPTIONS = { "skills/walkthrough/reference/storyboard-schema.md" => "Opus names the audio codec" }.freeze

  def self.key(path, line) = Digest::SHA256.hexdigest("#{path}\n#{line}")

  # { key => [path, line] } and the count of markers, over skills/**.
  def self.scan(root = ROOT)
    hits = {}
    markers = []
    Dir.glob(File.join(root, "skills", "**", "*.{md,js}")).sort.each do |file|
      path = file.delete_prefix("#{root}/")
      File.foreach(file, encoding: "UTF-8").each_with_index do |raw, index|
        line = raw.scrub.strip
        next unless line.match?(TIER) || line.match?(MARKER)

        if (marker = line.match(MARKER))
          markers << [ path, index + 1, marker[:reason].strip ]
        elsif line.match?(TIER)
          hits[key(path, line)] = [ path, line ]
        end
      end
    end
    [ hits, markers ]
  end

  def allowed
    File.file?(ALLOWLIST) ? Array(YAML.safe_load_file(ALLOWLIST)["entries"]) : []
  end

  def test_no_new_tier_literal_in_skills
    hits, = self.class.scan
    listed = allowed.to_h { |entry| [ entry["key"], entry ] }
    fresh = hits.reject { |key, _| listed.key?(key) }
    assert_empty fresh.values.map { |path, line| "#{path}: #{line}" },
                 "skills name roles ({{model:<role>}} / model: {{model-js:<role>}}), not tiers. " \
                 "Use a role, or add `model-roles: allow <reason>` to the line."
  end

  def test_allowlist_has_no_stale_entries
    hits, = self.class.scan
    stale = allowed.reject { |entry| hits.key?(entry["key"]) }
    assert_empty stale.map { |entry| "#{entry['path']}: #{entry['line']}" },
                 "these literals are gone; delete their entries from the allowlist in the PR that cleared them"
  end

  def test_allowlist_keys_match_their_readable_lines
    wrong = allowed.reject { |entry| entry["key"] == self.class.key(entry["path"], entry["line"]) }
    assert_empty wrong.map { |entry| entry["path"] }
  end

  def test_every_marker_carries_a_reason
    _, markers = self.class.scan
    bare = markers.select { |_, _, reason| reason.empty? }
    assert_empty bare.map { |path, line, _| "#{path}:#{line}" }, "model-roles: allow needs a reason"
  end

  def test_markers_are_counted_and_limited_once_the_allowlist_is_gone
    _, markers = self.class.scan
    puts "model-roles markers: #{markers.size}"
    return unless allowed.empty?

    stray = markers.reject { |path, _, _| MARKER_EXCEPTIONS.key?(path) }
    assert_empty stray.map { |path, line, _| "#{path}:#{line}" }, "with the allowlist gone, a marker needs a MARKER_EXCEPTIONS entry"
  end

  def test_a_new_literal_fails_even_when_another_in_the_same_file_was_removed
    old = self.class.key("skills/x/SKILL.md", "use opus here")
    refute_equal old, self.class.key("skills/x/SKILL.md", "use sonnet here")
    refute_equal old, self.class.key("skills/y/SKILL.md", "use opus here")
  end
end
