# frozen_string_literal: true

require "minitest/autorun"

# A raw start_with? containment check (a path compared against a computed
# root prefix) is lexical: it ignores symlinks, so the check and the read it
# guards can see different files. Containment goes through PathCanon. A
# start_with? against a plain string literal ('/', '--', '#') is not
# containment and is not flagged.
class PathContainmentLintTest < Minitest::Test
  SCRIPTS = File.expand_path("../scripts", __dir__)
  EXEMPT = "path_canon.rb"
  PATHISH = /expand_path|realpath|root|dir|path|home/
  # start_with?( whose argument is anything but one plain string literal.
  COMPUTED = /start_with\?\((?!\s*'[^']*'\s*\))(?!\s*"[^"#]*"\s*\))/

  # "file: stripped line" => why it is not a containment check.
  ALLOWLIST = {
    "cf_install_manifest.rb: raise ArgumentError, 'installation manifest escapes home' unless data['entries'].all? { |entry| " \
    "entry.is_a?(Hash) && entry['path'].is_a?(String) && File.expand_path(entry['path']).start_with?(\"\#{@home}/\") }" =>
      "string sanity of a stored manifest; safe_path? does the symlink-aware check before any entry is touched",
    "color_compile.rb: unless path_abs.start_with?(prefix)" =>
      "maps a host path to its lexical in-container mount path; resolving symlinks would point outside the mount",
    "plan_paths.rb: str.start_with?(\"\#{home}/\") ? str.sub(home, '~') : str" =>
      "display only: collapses the home prefix to ~ in rendered text",
    "plan_visuals.rb: known = plan_text.include?(path) || files.any? { |f| f == path || f.end_with?(\"/\#{path}\") || f.start_with?(path) }" =>
      "matches a diagram label against the PR's changed-file names; nothing is read from disk",
    "simplicity_signals.rb: out.each_line.any? { |hit| !hit.start_with?(\"\#{range.head}:\#{path}:\#{line}:\") }" =>
      "skips the definition's own line in git grep output; a commit-and-path string, not a filesystem path",
    "change_schedule_config.rb: prefix = prefixes.find { |candidate| path.start_with?(candidate) }" =>
      "matches dotted schema field names from ChangeSchema::FIELDS; no filesystem path"
  }.freeze

  def hits
    Dir.glob(File.join(SCRIPTS, "**", "*.rb")).sort.flat_map do |file|
      rel = file.delete_prefix("#{SCRIPTS}/")
      next [] if rel == EXEMPT

      File.readlines(file).filter_map do |line|
        "#{rel}: #{line.strip}" if line.match?(COMPUTED) && line.match?(PATHISH)
      end
    end
  end

  def test_no_raw_start_with_containment_outside_path_canon
    unexpected = hits.reject { |hit| ALLOWLIST.key?(hit) }
    assert_empty unexpected, "use PathCanon.within?/relative instead, or allowlist with a reason:\n#{unexpected.join("\n")}"
  end

  def test_allowlist_has_no_stale_entries
    assert_empty ALLOWLIST.keys - hits, "allowlisted lines no longer exist; drop them"
  end

  def test_the_pattern_catches_a_computed_prefix_and_ignores_a_literal
    assert "real.start_with?(\"\#{root}/\")".match?(COMPUTED)
    assert "path.start_with?(base + File::SEPARATOR)".match?(COMPUTED)
    refute "path.start_with?('/')".match?(COMPUTED)
    refute "dir.start_with?('--')".match?(COMPUTED)
  end
end
