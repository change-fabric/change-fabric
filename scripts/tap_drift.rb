# frozen_string_literal: true

# Compares the newest skills/v* tag with the version in the Homebrew tap
# formula's url line. tap-drift.yml feeds it the tag list and the formula text
# from the GitHub API, and reads the printed key=value lines.
module TapDrift
  TAG = %r{\Askills/v(\d+\.\d+\.\d+)\z}
  URL = %r{^\s*url\s+"[^"]*/skills/v(\d+\.\d+\.\d+)\.tar\.gz"}

  module_function

  def latest_tag(names)
    names.filter_map { |n| n[TAG, 1] }.max_by { |v| Gem::Version.new(v) }
  end

  def formula_version(text) = text[URL, 1]

  def behind?(tag, formula) = Gem::Version.new(tag) > Gem::Version.new(formula)
end

if $PROGRAM_NAME == __FILE__
  tag = TapDrift.latest_tag(File.readlines(ARGV.fetch(0), chomp: true)) or abort "no skills/v* tag found"
  formula = TapDrift.formula_version(File.read(ARGV.fetch(1))) or abort "no url version in formula"
  puts "tag=#{tag}", "formula=#{formula}", "behind=#{TapDrift.behind?(tag, formula)}"
end
