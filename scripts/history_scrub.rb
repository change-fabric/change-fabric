#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'tempfile'

# Human-run companion to client_name_guard.rb. That guard stops a sensitive
# client, customer, or downstream-project name from being authored into this
# repo going forward; this scrubs the ones already committed, out of the whole
# reachable history (every local branch and tag), in both commit messages and
# historical blob content, since an old version of a file can carry a name the
# current working tree no longer mentions.
#
# Like the guard, it hardcodes no names: terms come from the same user-local,
# never-committed ~/.claude/cf/sensitive_terms.txt (or --terms-file /
# CF_SENSITIVE_TERMS_FILE, or ad hoc --term flags). This repo is shared across
# projects, so committing the term list here would leak exactly what it names.
#
# Rewriting published history is destructive and irreversible without the
# backup, so the default is analysis-only: it reports what it would change and
# exits. --rewrite is the opt-in, and even then this never pushes; it prints
# the exact push commands for a human to run.
module HistoryScrub
  DEFAULT_TERMS_PATH = File.join(Dir.home, '.claude', 'cf', 'sensitive_terms.txt')
  DEFAULT_REPLACEMENT = 'REDACTED'
  SAMPLE_LIMIT = 20

  # Where git-filter-repo lands from a `pip install --user`, which is how it is
  # usually installed on a machine whose git package does not ship it.
  EXTRA_BIN_DIRS = [ File.join(Dir.home, '.local', 'bin') ].freeze

  INSTALL_HINT = <<~HINT
    git-filter-repo not found. Install one of these ways, then re-run:
      pip install --user git-filter-repo    (lands in ~/.local/bin)
      brew install git-filter-repo
      dnf install git-filter-repo
  HINT

  module_function

  def run(argv, stdout: $stdout, stderr: $stderr)
    options = parse_args(argv, stderr)
    return 1 unless options

    terms = TermList.new(terms_path: options[:terms_path], extra: options[:terms]).terms
    if terms.empty?
      stderr.puts "[scrub] no terms to scrub (looked in #{options[:terms_path]}). Nothing to do."
      return 1
    end

    report = Scanner.new(terms).scan
    print_report(report, terms, stdout)
    return 0 unless options[:rewrite]

    rewrite(terms, report, options, stdout, stderr)
  end

  def rewrite(terms, report, options, stdout, stderr)
    if report.empty?
      stdout.puts '[scrub] history is already clean; nothing to rewrite.'
      return 0
    end

    filter_repo = find_filter_repo
    return fail_with(stderr, INSTALL_HINT) unless filter_repo

    blocker = Preflight.new.blocker
    return fail_with(stderr, "[scrub] refusing to rewrite: #{blocker}") if blocker

    Rewriter.new(terms, filter_repo: filter_repo, replacement: options[:replacement])
            .run(stdout, stderr)
  end

  def fail_with(stderr, message)
    stderr.puts message
    1
  end

  # git-filter-repo is a single script, so an executable file in a known bin
  # dir is as good as one on PATH; a user who pip-installed it may not have
  # ~/.local/bin exported in this shell.
  def find_filter_repo
    from_path = `command -v git-filter-repo 2>/dev/null`.strip
    return from_path unless from_path.empty?

    EXTRA_BIN_DIRS.map { |dir| File.join(dir, 'git-filter-repo') }
                  .find { |path| File.executable?(path) }
  end

  def parse_args(argv, stderr)
    options = {
      terms_path: ENV['CF_SENSITIVE_TERMS_FILE'] || DEFAULT_TERMS_PATH,
      terms: [], replacement: DEFAULT_REPLACEMENT, rewrite: false
    }
    parser = option_parser(options)
    parser.parse!(argv.dup)
    options
  rescue OptionParser::ParseError => e
    stderr.puts "#{e.message}\n\n#{parser}"
    nil
  end

  def option_parser(options)
    OptionParser.new do |o|
      o.banner = <<~BANNER
        usage: history_scrub.rb [options]

        Analyzes (and with --rewrite, purges) sensitive terms from this repo's entire
        git history: commit and tag messages plus historical file content, across every
        local branch and tag. Analysis-only by default. Never pushes anything.
      BANNER
      o.on('--terms-file PATH', "term list, one per line (default: #{DEFAULT_TERMS_PATH})") { |v| options[:terms_path] = v }
      o.on('--term TERM', 'additional ad hoc term; repeatable') { |v| options[:terms] << v }
      o.on('--replacement TEXT', "text each term becomes (default: #{DEFAULT_REPLACEMENT})") { |v| options[:replacement] = v }
      o.on('--rewrite', 'actually rewrite history (destructive; backs up first)') { options[:rewrite] = true }
      o.on('-h', '--help', 'show this message') { puts o; exit 0 }
    end
  end

  def print_report(report, terms, stdout)
    stdout.puts "[scrub] terms: #{terms.size} (#{terms.join(', ')})"
    stdout.puts "[scrub] commits with matches: #{report.commits.size}, blobs with matches: #{report.blobs.size}, " \
                "total occurrences: #{report.occurrences}"
    report.counts_by_term.each { |term, count| stdout.puts "  #{term}: #{count} occurrence(s)" }
    sample(report.commits, 'commit', stdout)
    sample(report.blobs, 'blob', stdout)
    stdout.puts '[scrub] clean: no occurrences anywhere in reachable history.' if report.empty?
  end

  def sample(hits, label, stdout)
    return if hits.empty?

    stdout.puts "[scrub] #{label} hits (first #{[ SAMPLE_LIMIT, hits.size ].min} of #{hits.size}):"
    hits.first(SAMPLE_LIMIT).each { |hit| stdout.puts "  #{hit}" }
  end

  # Reads the never-committed term list, plus any ad hoc --term values. Same
  # file format client_name_guard.rb reads: one term per line, '#' comments
  # and blank lines ignored.
  class TermList
    def initialize(terms_path:, extra: [])
      @terms_path = terms_path
      @extra = extra
    end

    def terms
      (from_file + @extra).map(&:strip).reject(&:empty?).uniq
    end

    private

    def from_file
      return [] unless File.file?(@terms_path)

      File.readlines(@terms_path).map(&:strip)
          .reject { |line| line.empty? || line.start_with?('#') }
    end
  end

  Report = Struct.new(:commits, :blobs, :counts_by_term) do
    def occurrences = counts_by_term.values.sum
    def empty? = occurrences.zero?
  end

  # Counts term occurrences across all reachable history without touching it:
  # every commit message, and every blob (deduped by oid, so a file unchanged
  # across 50 commits is read once).
  class Scanner
    def initialize(terms)
      @patterns = terms.to_h { |term| [ term, /#{Regexp.escape(term)}/i ] }
    end

    def scan
      counts = Hash.new(0)
      Report.new(scan_messages(counts), scan_blobs(counts), counts)
    end

    private

    def scan_messages(counts)
      hits = []
      `git log --all --format=%H%x1f%B%x1e`.split("\x1e").each do |record|
        sha, message = record.strip.split("\x1f", 2)
        next if sha.to_s.empty?

        found = tally(message.to_s, counts)
        hits << "#{sha[0, 12]}  #{message.to_s.lines.first.to_s.strip}" unless found.zero?
      end
      hits
    end

    def scan_blobs(counts)
      hits = []
      each_blob do |oid, path, content|
        found = tally(content, counts)
        hits << "#{oid[0, 12]}  #{path}" unless found.zero?
      end
      hits
    end

    def tally(text, counts)
      @patterns.sum do |term, pattern|
        found = text.scan(pattern).size
        counts[term] += found
        found
      end
    end

    # `rev-list --objects` gives oid+path for every reachable object; one
    # `cat-file --batch` stream then reads the blob bodies, so a large history
    # costs two git processes rather than one per object.
    def each_blob
      seen = {}
      `git rev-list --objects --all`.each_line do |line|
        oid, path = line.strip.split(' ', 2)
        seen[oid] = path if path && !seen.key?(oid)
      end
      return if seen.empty?

      read_batch(seen) { |oid, path, content| yield(oid, path, content) }
    end

    def read_batch(seen)
      IO.popen([ 'git', 'cat-file', '--batch' ], 'r+b') do |io|
        seen.each_key { |oid| io.puts(oid) }
        io.close_write
        while (header = io.gets)
          oid, type, size = header.split
          body = io.read(size.to_i.succ).to_s[0...size.to_i]
          # Skip binaries: a NUL byte means term matching is meaningless there.
          yield(oid, seen[oid], body) if type == 'blob' && !body.include?("\0")
        end
      end
    end
  end

  # State the repo must be in before history is rewritten, so the rewrite is
  # recoverable and does not silently swallow uncommitted work.
  class Preflight
    def blocker
      return 'not inside a git work tree.' unless `git rev-parse --is-inside-work-tree 2>/dev/null`.strip == 'true'
      return 'working tree is dirty; commit or stash first.' unless `git status --porcelain`.strip.empty?

      nil
    end
  end

  # Runs git-filter-repo over every ref, after bundling the pre-rewrite history
  # to a file outside the repo. A backup branch or tag would be useless here:
  # filter-repo rewrites every ref it finds, including any backup ref.
  class Rewriter
    def initialize(terms, filter_repo:, replacement:)
      @terms = terms
      @filter_repo = filter_repo
      @replacement = replacement
    end

    def run(stdout, stderr)
      backup = create_backup
      stdout.puts "[scrub] backup bundle: #{backup}"
      origin = `git remote get-url origin 2>/dev/null`.strip
      branches = local_branches

      return fail_run(stderr, backup) unless filter_repo!

      print_next_steps(stdout, backup, origin, branches)
      0
    end

    private

    def fail_run(stderr, backup)
      stderr.puts "[scrub] git-filter-repo failed; history may be partially rewritten. Restore from #{backup}."
      1
    end

    def create_backup
      path = File.expand_path("../cf-history-backup-#{Time.now.strftime('%Y%m%d%H%M%S')}.bundle", Dir.pwd)
      raise "backup bundle failed: #{path}" unless system('git', 'bundle', 'create', path, '--all')

      path
    end

    def local_branches
      `git for-each-ref --format=%(refname:short) refs/heads`.split("\n").map(&:strip).reject(&:empty?)
    end

    def filter_repo!
      Tempfile.create('cf-scrub-replacements') do |file|
        file.write(@terms.map { |term| rule(term) }.join("\n"))
        file.flush
        # --replace-text covers blob content, --replace-message covers commit
        # and tag messages; neither implies the other.
        system(@filter_repo, '--force', '--replace-text', file.path, '--replace-message', file.path)
      end
    end

    # filter-repo rules are Python regexes; escape everything non-alphanumeric
    # so a term containing a dot (a domain) matches literally, and prefix (?i)
    # so casing and mid-URL substrings are caught alike.
    def rule(term)
      "regex:(?i)#{term.gsub(/[^A-Za-z0-9_]/) { |c| "\\#{c}" }}==>#{@replacement}"
    end

    def print_next_steps(stdout, backup, origin, branches)
      stdout.puts <<~DONE

        [scrub] history rewritten locally. NOTHING has been pushed.
        Re-run this script without --rewrite to confirm zero occurrences remain.

        To publish (each line is yours to run, after you have verified the result):
          git remote add origin #{origin.empty? ? '<origin-url>' : origin}
          git fetch origin
        #{branches.map { |b| "  git push --force-with-lease origin #{b}" }.join("\n")}
          git push --force origin --tags

        Then: every other clone of this repo must be re-cloned, and open PRs
        referencing old SHAs should be closed. GitHub keeps unreachable objects
        cached until GC, so ask support to purge them if the leak was serious.

        To undo before pushing:
          git fetch #{backup} 'refs/*:refs/*' --force
      DONE
    end
  end
end

exit(HistoryScrub.run(ARGV)) if __FILE__ == $PROGRAM_NAME
