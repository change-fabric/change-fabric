# frozen_string_literal: true

require 'json'

# Splits test/*_test.rb across CI shards, and checks that the shards together
# ran every test file exactly once.
#
# The split is computed, not listed: every file gets a weight (its measured
# seconds when it is one of the slow browser-capture files in WEIGHTS, else
# DEFAULT_WEIGHT), and files are dealt heaviest first to the lightest shard,
# ties broken by name and then by shard index. That is deterministic for a
# given file list, keeps the slow files on separate shards, and means a newly
# added test file lands in some shard with no edit here. A file whose cost
# grows is one line in WEIGHTS.
#
# The guard does not trust the split: each shard job reports the files it
# actually ran, and `verify` fails unless those reports cover the current
# test/*_test.rb listing exactly, with no duplicate and no missing file, and
# the shards' run counts add up to at least MIN_RUNS.
module TestShards
  module_function

  GLOB = 'test/*_test.rb'

  # Seconds per file from one local run, rounded: every file over about 5s.
  # The rest are short enough that a flat weight balances them.
  WEIGHTS = {
    'test/walkthrough_diagram_capture_test.rb' => 115,
    'test/walkthrough_diagram_lanes_capture_test.rb' => 80,
    'test/walkthrough_environment_capture_test.rb' => 60,
    'test/color_check_test.rb' => 50,
    'test/install_test.rb' => 30,
    'test/walkthrough_live_browser_test.rb' => 20,
    'test/walkthrough_crisp_docker_test.rb' => 20,
    'test/walkthrough_diagram_lanes_generated_test.rb' => 17,
    'test/prototype_ux_lint_test.rb' => 16,
    'test/agent_contract_test.rb' => 9,
    'test/walkthrough_pass2_docker_test.rb' => 7,
    'test/change_artifact_test.rb' => 7
  }.freeze
  DEFAULT_WEIGHT = 1.0

  # Floor on the total runs across shards. The suite had 2,491 when this was
  # written; a drop below the floor means tests stopped loading, not that a
  # shard was rebalanced.
  MIN_RUNS = 2_450

  def files(root = Dir.pwd)
    Dir.chdir(root) { Dir[GLOB].sort }
  end

  def weight(file) = WEIGHTS.fetch(file, DEFAULT_WEIGHT)

  # Every shard's file list, index 0 first.
  def split(all, total)
    raise ArgumentError, "shard total must be positive, got #{total}" unless total.positive?

    shards = Array.new(total) { [] }
    loads = Array.new(total, 0.0)
    all.sort_by { |f| [ -weight(f), f ] }.each do |f|
      i = loads.each_with_index.min_by { |load, idx| [ load, idx ] }.last
      shards[i] << f
      loads[i] += weight(f)
    end
    shards.map(&:sort)
  end

  # The files for shard `index` of `total`, 1-based, from a "2/4" spec.
  def for_spec(spec, all = files)
    index, total = parse(spec)
    split(all, total)[index - 1]
  end

  def parse(spec)
    m = /\A(\d+)\/(\d+)\z/.match(spec.to_s.strip)
    raise ArgumentError, "TEST_SHARD must look like 2/4, got #{spec.inspect}" unless m

    index = m[1].to_i
    total = m[2].to_i
    raise ArgumentError, "shard #{index} is outside 1..#{total}" unless index.between?(1, total)

    [ index, total ]
  end

  # Problems with a set of shard reports (each { 'files' => [...], 'runs' => n })
  # against the expected file list. Empty means the shards covered it.
  def problems(reports, expected, min_runs: MIN_RUNS)
    ran = reports.flat_map { |r| Array(r['files']) }
    errors = []
    dupes = ran.tally.select { |_, n| n > 1 }.keys.sort
    errors << "ran in more than one shard: #{dupes.join(', ')}" unless dupes.empty?
    missing = expected - ran
    errors << "never ran: #{missing.join(', ')}" unless missing.empty?
    extra = ran.uniq - expected
    errors << "ran but not in #{GLOB}: #{extra.join(', ')}" unless extra.empty?
    runs = reports.sum { |r| r['runs'].to_i }
    errors << "only #{runs} runs across shards, expected at least #{min_runs}" if runs < min_runs
    errors
  end

  # The run count from minitest's summary line in a shard's output.
  def runs_in(output)
    line = output.to_s.lines.grep(/\A\d+ runs, \d+ assertions/).last
    line ? line.to_i : 0
  end

  def cli(argv, out: $stdout, err: $stderr)
    case argv.first
    when 'list'
      out.puts(for_spec(argv[1]))
      0
    when 'report'
      _, spec, log, dest = argv
      File.write(dest, JSON.generate('shard' => spec, 'files' => for_spec(spec), 'runs' => runs_in(File.read(log))))
      0
    when 'verify'
      reports = argv.drop(1).map { |path| JSON.parse(File.read(path)) }
      errors = problems(reports, files)
      errors.each { |e| err.puts "test shards: #{e}" }
      out.puts "test shards: #{reports.size} shards ran #{reports.sum { |r| r['runs'].to_i }} tests" if errors.empty?
      errors.empty? ? 0 : 1
    else
      err.puts 'usage: test_shards.rb list N/T | report N/T LOG OUT.json | verify REPORT.json...'
      2
    end
  end
end

exit TestShards.cli(ARGV) if $PROGRAM_NAME == __FILE__
