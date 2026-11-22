#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'tempfile'
require 'yaml'
require_relative 'change_flow_compiler'
require_relative 'change_frontmatter'
require_relative 'change_selector_suggestions'
require_relative 'change_suite'

# Case drafts: reads a pull request diff and the routes in CHANGE.md and writes
# DRAFT test cases to a run output directory. A draft is never a suite: it is
# refused anywhere inside the repository, so nothing here can reach a suites
# tree, and a person promotes a case by reading it and copying it into a suite.
#
# The draft is a skeleton: one case per route the diff appears to touch,
# visiting it and checking the status. A diff that touches no known route is
# not written at all. `redact` masks text bound for a model with the shared
# line-oriented masker (the model path lands separately). Sensitive files
# contribute their name only, and every value that reaches a draft or a
# message is stripped of control characters and truncated.
class ChangeCaseDraft
  class Error < StandardError; end

  Source = Struct.new(:label, :paths, :added, keyword_init: true)
  Draft = Struct.new(:path, :cases, :origin, :notes, keyword_init: true)

  CLIP = 100
  MAX_DIFF_BYTES = 2_000_000
  MAX_PATHS = 50
  MAX_CASES = 5
  ROUTE_LANES = %w[browserless a11y].freeze
  ROOT_FILES = %w[page index home layout].freeze
  ROOT_DIRS = %w[. app pages src src/app src/pages public].freeze
  SENSITIVE_PATH = %r{(\A|/)(\.env[^/]*|[^/]*\.(pem|key|p12|pfx)|[^/]*(secret|credential)[^/]*)\z}i
  SECRET_ENV_NAME = /(token|secret|passw|key|auth|credential|cookie)/i
  # A route is only visitable when it is a plain path.
  VISITABLE = %r{\A/[A-Za-z0-9._~/%-]*\z}

  # A value fit for a draft or a message: control characters gone, truncated.
  def self.clip(value, max = CLIP)
    text = value.to_s.gsub(/[[:cntrl:]]/, ' ')
    text.length > max ? "#{text[0, max]}..." : text
  end

  # Text bound for the model or a draft: masked line by line (credentials,
  # quoted values with spaces, multiline values, URL userinfo) by the shared
  # helper, plus the values of secret-looking environment variables.
  def self.redact(text, env: ENV)
    secrets = env.select { |name, value| name.match?(SECRET_ENV_NAME) && value.to_s.length >= 8 }.values
    ChangeSelectorSuggestions.mask(text, secrets: secrets)
  end

  # A unified diff as changed paths plus the added lines of each non-sensitive
  # file. A deleted file is not a path a draft can cover; a rename counts as
  # its new path, and a binary change as its path with no added lines. Hunk
  # line counts tell a content line that looks like a header from a real one.
  def self.parse_diff(text, label:)
    paths = []
    added = Hash.new { |hash, key| hash[key] = [] }
    file = nil
    left = right = 0
    finish = lambda do
      next unless file && file[:path] && !file[:deleted]

      paths << file[:path] unless paths.include?(file[:path])
      added[file[:path]].concat(file[:added]) unless SENSITIVE_PATH.match?(file[:path])
    end
    text.to_s.scrub.each_line do |raw|
      line = raw.chomp
      left = right = 0 if line.start_with?('diff --git ')
      if left.positive? || right.positive?
        left -= 1 unless line.start_with?('+', '\\')
        right -= 1 unless line.start_with?('-', '\\')
        file[:added] << line[1..] if line.start_with?('+')
        next
      end
      if line.start_with?('diff --git ')
        finish.call
        file = { path: header_path(line), deleted: false, added: [] }
      elsif line.start_with?('+++ ')
        finish.call if file.nil? || file[:seen]
        file = { path: nil, deleted: false, added: [] } if file.nil? || file[:seen]
        file[:seen] = true
        target = line.delete_prefix('+++ ')
        target == '/dev/null' ? file[:deleted] = true : file[:path] = path_of(target.sub(/\t.*/, ''), strip: true)
      elsif file && file[:seen] && line.start_with?('+')
        file[:added] << line[1..]
      elsif file && (record = line.match(/\A(?:rename|copy) to (.*)/))
        file[:path] = path_of(record[1])
      elsif file && line.start_with?('deleted file mode')
        file[:deleted] = true
      elsif file && (hunk = line.match(/\A@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/))
        left = (hunk[1] || 1).to_i
        right = (hunk[2] || 1).to_i
      end
    end
    finish.call
    Source.new(label: label, paths: paths, added: added)
  end

  # `diff --git a/P b/P`: the path when both sides name the same one.
  def self.header_path(line)
    rest = line.delete_prefix('diff --git ')
    match = rest.match(%r{\Aa/(.+) b/\1\z})
    quoted = rest.match(%r{\A"a/(.+)" "b/\1"\z})
    match ? path_of(match[1]) : quoted && path_of("\"#{quoted[1]}\"")
  end

  # A git-quoted path: backslash escapes and octal bytes decoded.
  def self.unquote(raw)
    decoded = raw.b.delete_prefix('"').delete_suffix('"').gsub(/\\([0-7]{3}|.)/n) do
      code = Regexp.last_match(1)
      code.length == 3 ? [ code.to_i(8) & 0xFF ].pack('C') : { 'n' => "\n", 't' => "\t" }.fetch(code, code)
    end
    decoded.force_encoding(Encoding::UTF_8).scrub
  end

  def self.path_of(raw, strip: false)
    path = raw.start_with?('"') ? unquote(raw) : raw
    path = path.sub(%r{\Ab/}, '') if strip
    path.empty? || path.start_with?('/') || path.split('/').include?('..') ? nil : path
  end

  def self.read_pr(number)
    raise Error, "--pr needs a pull request number, got #{clip(number).inspect}" unless number.to_s.match?(/\A[1-9]\d{0,8}\z/)

    out, err, status = Open3.capture3('gh', 'pr', 'diff', number.to_s)
    raise Error, "gh pr diff #{number} failed: #{clip(err, 200)}" unless status.success?

    parse_diff(bounded(out), label: "pr-#{number}")
  rescue Errno::ENOENT
    raise Error, 'gh is not installed, so --pr cannot read a diff; use --diff <file>'
  end

  def self.read_diff(path)
    raise Error, "--diff file not found: #{clip(path)}" unless File.file?(path)

    parse_diff(bounded(File.read(path, MAX_DIFF_BYTES + 1, encoding: 'UTF-8')), label: "diff-#{slug(File.basename(path, '.*'))}")
  rescue SystemCallError => e
    raise Error, "--diff could not be read: #{clip(e.message, 200)}"
  end

  def self.bounded(text) = text.to_s.byteslice(0, MAX_DIFF_BYTES)

  def self.slug(value)
    text = value.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
    text[0, 60].gsub(/-+\z/, '')
  end

  # The paths of the browserless and a11y lanes in a CHANGE.md, in order, each
  # once. A route that is not a plain visitable path is left out.
  def self.read_routes(change_path)
    raise Error, "CHANGE.md not found: #{clip(change_path)}" unless File.file?(change_path)

    lanes = ChangeFrontmatter.parse_file(change_path).dig('change_config', 'lanes')
    return [] unless lanes.is_a?(Hash)

    ROUTE_LANES.flat_map { |lane| lanes[lane].is_a?(Hash) ? Array(lanes[lane]['routes']) : [] }
               .map { |item| item.is_a?(Hash) ? item['path'] : item }
               .map(&:to_s).select { |path| VISITABLE.match?(path) }.uniq
  end

  attr_reader :source, :routes, :out, :root

  def initialize(source, routes:, out:, root:)
    @source = source
    @routes = routes
    @out = out
    @root = root
  end

  # Writes the draft and returns it, or nil when there is nothing to draft.
  def write
    raise Error, 'the diff changes no files, so there is nothing to draft' if source.paths.empty?
    refuse_inside_repo!(out)

    cases, origin, notes = build
    return nil if cases.empty?

    slug = self.class.slug(source.label)
    document = { 'suite' => "draft-#{slug}", 'suite_version' => ChangeSuiteSchema::SUITE_VERSION, 'cases' => cases }
    verify(document)
    path = File.join(out, 'drafts', "#{slug}.cf-testcases.yml")
    FileUtils.mkdir_p(File.dirname(path))
    refuse_inside_repo!(path)
    File.write(path, header(origin, notes) + YAML.dump(document))
    Draft.new(path: path, cases: cases, origin: origin, notes: notes)
  end

  private

  def build = [ skeleton_cases, 'skeleton', [] ]

  # --- skeleton ---------------------------------------------------------------

  # One case per route the diff appears to touch: every segment of the route
  # appears in a changed path. The root route matches only a page-like file directly in a top directory.
  def skeleton_cases
    matched = routes.filter_map do |route|
      hits = source.paths.select { |path| touches?(route, path) }
      [ route, hits ] unless hits.empty?
    end
    ids = {}
    matched.first(MAX_CASES).each_with_index.map { |(route, hits), index| skeleton_case(route, hits, ids, index) }
  end

  def touches?(route, path)
    tokens = path.downcase.split(%r{[^a-z0-9]+}).reject(&:empty?)
    segments = route.downcase.split('/').flat_map { |part| part.split(/[^a-z0-9]+/) }.reject(&:empty?)
    return root_file?(path) if segments.empty?

    (segments - tokens).empty?
  end

  # The root route is touched by a page-like file sitting directly in a
  # conventional top directory, never by one nested under another route.
  def root_file?(path)
    ROOT_FILES.include?(File.basename(path, '.*').downcase) && ROOT_DIRS.include?(File.dirname(path))
  end

  def skeleton_case(route, hits, ids, index)
    covers = hits.reject { |path| path.match?(/[*?\[\]{}]/) }.first(MAX_PATHS)
    slug = self.class.slug(route)
    item = { 'id' => unique_id("route-#{slug.empty? ? 'root' : slug}", ids, index),
             'acceptance' => "DRAFT: #{self.class.clip(route)} still loads after this change; replace with what the change should do.",
             'steps' => [ { 'goto' => route }, { 'expect_status' => 200 } ] }
    item['covers'] = covers unless covers.empty?
    item
  end

  def unique_id(slug, ids, index)
    base = slug.empty? ? "case-#{index + 1}" : slug
    id = ids.key?(base) ? "#{base}-#{index + 1}" : base
    ids[id] = true
    id
  end

  # --- output -----------------------------------------------------------------

  def header(origin, notes)
    lines = [ "# DRAFT cases for #{self.class.clip(source.label)} (#{origin}). Not a suite: review every case, then promote the ones",
              '# you keep by copying them into a suite file under qa/. Nothing here is run or gated until then.' ]
    notes.each { |note| lines << "# note: #{self.class.clip(note, 160)}" }
    "#{lines.join("\n")}\n"
  end

  # The draft round-trips through the lane's own parser, so a case that would
  # be refused at promotion is refused here instead.
  def verify(document)
    Tempfile.create([ 'cf-draft', '.cf-testcases.yml' ]) do |file|
      file.write(YAML.dump(document))
      file.flush
      ChangeSuite.load_file(file.path)
    end
  rescue ChangeSuite::Error => e
    raise Error, "the draft is not a valid suite file: #{self.class.clip(e.message, 200)}"
  end

  # A draft inside the repository could be picked up by a suites glob, so the
  # destination must resolve outside it. Checked for the output directory and
  # again for the final path, because `drafts` or the file may be a symlink.
  def refuse_inside_repo!(path)
    target = resolve(path)
    base = resolve(root)
    return unless target == base || target.start_with?("#{base}/")

    raise Error, "#{self.class.clip(path)} resolves inside the repository; drafts go to run output only"
  end

  def resolve(path)
    pathname = Pathname.new(File.expand_path(path))
    pathname = pathname.dirname until pathname.exist?
    suffix = Pathname.new(File.expand_path(path)).relative_path_from(pathname)
    File.expand_path(suffix.to_s, pathname.realpath.to_s)
  end
end

if $PROGRAM_NAME == __FILE__
  options = { change: 'CHANGE.md' }
  begin
    OptionParser.new do |opts|
      opts.banner = 'Usage: change_case_draft.rb (--pr N | --diff FILE) --out DIR [--change CHANGE.md]'
      opts.on('--pr N') { |value| options[:pr] = value }
      opts.on('--diff FILE') { |value| options[:diff] = value }
      opts.on('--out DIR') { |value| options[:out] = value }
      opts.on('--change PATH') { |value| options[:change] = value }
    end.parse!
    raise ChangeCaseDraft::Error, 'give exactly one of --pr and --diff' if [ options[:pr], options[:diff] ].count(&:nil?) != 1
    raise ChangeCaseDraft::Error, '--out is required' unless options[:out]

    source = options[:pr] ? ChangeCaseDraft.read_pr(options[:pr]) : ChangeCaseDraft.read_diff(options[:diff])
    draft = ChangeCaseDraft.new(source, routes: ChangeCaseDraft.read_routes(options[:change]), out: options[:out],
                                       root: File.dirname(File.expand_path(options[:change]))).write
    if draft
      puts "case drafts: #{draft.cases.size} draft case(s) from #{draft.origin}: #{draft.path}"
    else
      puts 'case drafts: no draft written (no route matched the diff)'
    end
  rescue OptionParser::ParseError, ChangeCaseDraft::Error, SystemCallError => e
    warn "case drafts: #{ChangeCaseDraft.clip(e.message, 200)}"
    exit 2
  end
end
