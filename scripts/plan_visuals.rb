#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'tempfile'
require_relative 'change_screenshot_upload'

# Carries a cf:plan's diagrams onto the pull requests that execute it. Four
# verbs: `select` routes each Visuals-section line to a phase's PR by its
# `(phases: ...)` tag, `check` asks whether a diagram still matches what the PR
# does, `compose` builds the marker-wrapped "Plan visuals" body section from
# upload urls, and `post` uploads the PNGs and splices that section into the PR
# body. Posting is idempotent by a hash of the SVG content, and any failed
# upload leaves the body untouched (SS-1), so a re-run after a watcher re-entry
# or a flaky upload is always safe. Nothing here decides whether the PR has
# settled unless asked with --require-settled; the caller owns that gate.
module PlanVisuals
  PHASE_TAG = /\(phases: (all|\d+(?:,\d+)*)\)/
  START_PREFIX = '<!-- cf:plan-visuals sha='
  END_MARK = '<!-- /cf:plan-visuals -->'
  SECTION = /<!-- cf:plan-visuals sha=(\h*) -->.*?<!-- \/cf:plan-visuals -->/m
  VISUALS_HEADING = /^## Visuals\s*$/
  DIGEST_EXCLUDED = /^## (?:Visuals|Roast)\s*$/
  FIRST_PR_TYPES = %w[architecture timeline schedule].freeze
  TIMELINE_TYPES = %w[timeline schedule].freeze
  EXTENSIONS = %w[rb js mjs ts tsx jsx md json yml yaml svg png sh css html erb py go toml lock].freeze
  # A label reads as a path when it ends in a known file extension (with or
  # without directories) or is a directory ending in a slash. A bare slash is
  # not enough: "match/drift" in a flow diagram is prose, not a path.
  PATH_LIKE = %r{(?:[\w~.-]+/)*[\w.-]*\w\.(?:#{EXTENSIONS.join('|')})\b|(?:[\w~.-]+/)+(?=[\s<]|\z)}
  LABEL_TAGS = /<(text|tspan|title|desc)\b[^>]*>(.*?)<\/\1>/m
  SETTLED_CONCLUSIONS = %w[SUCCESS SKIPPED NEUTRAL].freeze

  Visual = Data.define(:name, :svg, :type, :phases) do
    def all? = phases == 'all'
    def phase_numbers = all? ? [] : phases.split(',').map(&:to_i)
    def first_pr_only? = all? || FIRST_PR_TYPES.include?(type)
    def timeline? = TIMELINE_TYPES.include?(type)
  end

  # Shells out to gh. Tests pass any object answering #run(*argv, stdin:).
  class Gh
    def run(*argv, stdin: nil)
      out, status = Open3.capture2e(*argv, stdin_data: stdin.to_s)
      [ out, status.success? ]
    rescue StandardError => e
      [ e.message, false ]
    end
  end

  module_function

  # Every `.svg` named in the plan's Visuals section, in section order. An
  # untagged line (a plan landed before tags existed) counts as `all`.
  def visuals(plan_dir)
    section = visuals_section(File.join(plan_dir, 'plan.md'))
    return [] unless section

    section.lines.filter_map do |line|
      rel = line[%r{[\w./-]+\.svg}]
      next unless rel

      svg = File.join(plan_dir, rel)
      Visual.new(name: File.basename(rel, '.svg'), svg: svg, type: svg_type(svg),
                 phases: line[PHASE_TAG, 1] || 'all')
    end.uniq(&:name)
  end

  def visuals_section(plan_path)
    return nil unless File.exist?(plan_path)

    body = File.read(plan_path).split(/^(?=## )/).find { |part| part.match?(VISUALS_HEADING) }
    body&.sub(VISUALS_HEADING, '')
  end

  def svg_source(svg) = File.exist?(svg) ? File.read(svg) : ''

  def svg_type(svg) = svg_source(svg)[/data-(?:diagram|chart)-type="([^"]+)"/, 1]

  # V2 routing. Phase 1's PR carries `all`, architecture, and timeline visuals
  # plus its own tags; a later PR carries only its own tags, else a link back.
  # A nil phase means a single-PR plan, which carries everything.
  def select(plan_dir, phase: nil)
    all = visuals(plan_dir)
    return { visuals: all, link_back: false } if phase.nil?

    chosen = all.select do |v|
      phase == 1 ? (v.first_pr_only? || v.phase_numbers.include?(1)) : (!v.first_pr_only? && v.phase_numbers.include?(phase))
    end
    { visuals: chosen, link_back: phase > 1 && chosen.empty? }
  end

  # sha256 of plan.md minus the sections steps 7a and 7b append after drawing.
  def plan_digest(plan_path)
    kept = File.read(plan_path).split(/^(?=## )/).reject { |part| part.match?(DIGEST_EXCLUDED) }
    Digest::SHA256.hexdigest(kept.join)
  end

  # Declared phases in meta.phases, not phase( call sites: the plan template
  # runs its build phases from one call inside a loop.
  def workflow_phase_count(plan_dir) = phase_titles(plan_dir).size

  def phase_titles(plan_dir)
    path = File.join(plan_dir, 'workflow.js')
    return [] unless File.exist?(path)

    block = File.read(path)[/phases:\s*\[(.*?)\]/m, 1].to_s
    block.scan(/title:\s*"([^"]*)"/).flatten
  end

  def manifest(plan_dir)
    path = File.join(plan_dir, 'diagrams', 'manifest.json')
    File.exist?(path) ? JSON.parse(File.read(path)) : nil
  rescue JSON::ParserError
    nil
  end

  def labels(svg)
    svg_source(svg).scan(LABEL_TAGS).map { |_, inner| inner.gsub(/<[^>]+>/, ' ') }
  end

  def tokens(text) = text.to_s.downcase.split(/[^a-z0-9]+/).reject(&:empty?)

  def title_overlap(phase_title, *candidates)
    want = tokens(phase_title).uniq
    return 1.0 if want.empty?

    have = candidates.flat_map { |c| tokens(c) }
    (want & have).size.fdiv(want.size)
  end

  # V3, the deterministic half. Each rule adds a drift or an inconclusive
  # reason; a timeline turns inconclusive into drift, since its one question
  # (does the phase count still hold) has a mechanical answer.
  def check_visual(visual, plan_dir:, pr:, phase:, manifest:, plan_text: File.read(File.join(plan_dir, 'plan.md')))
    drift = []
    unsure = []
    check_paths(visual, plan_text, pr[:files], drift)
    check_title(plan_dir, phase, pr, unsure)
    check_digest(plan_dir, manifest, drift, unsure)
    check_timeline(visual, plan_dir, manifest, drift, unsure) if visual.timeline?
    if visual.timeline? && !unsure.empty?
      drift.concat(unsure)
      unsure = []
    end
    verdict = if drift.any? then 'drift' elsif unsure.any? then 'inconclusive' else 'match' end
    { name: visual.name, verdict: verdict, reasons: drift + unsure }
  end

  def check_paths(visual, plan_text, files, drift)
    return drift << "#{visual.name}.svg missing" unless File.exist?(visual.svg)

    labels(visual.svg).flat_map { |l| l.scan(PATH_LIKE) }.uniq.each do |path|
      known = plan_text.include?(path) || files.any? { |f| f == path || f.end_with?("/#{path}") || f.start_with?(path) }
      drift << "label #{path} is in neither the PR files nor plan.md" unless known
    end
  end

  def check_title(plan_dir, phase, pr, unsure)
    titles = phase_titles(plan_dir)
    title = phase ? titles[phase - 1] : titles.max_by { |t| title_overlap(t, pr[:title], pr[:branch]) }
    return unsure << 'no phase title in workflow.js' unless title

    overlap = title_overlap(title, pr[:title], pr[:branch])
    unsure << "phase title \"#{title}\" overlaps the PR title or branch #{(overlap * 100).round} percent" if overlap < 0.5
  end

  def check_digest(plan_dir, manifest, drift, unsure)
    return unsure << 'no diagrams/manifest.json' unless manifest

    drift << 'plan.md changed since the diagram was drawn' unless manifest['plan_sha256'] == plan_digest(File.join(plan_dir, 'plan.md'))
  end

  def check_timeline(visual, plan_dir, manifest, drift, _unsure)
    return unless manifest

    drawn = manifest['workflow_phase_count']
    now = workflow_phase_count(plan_dir)
    drift << "#{visual.name} drawn for #{drawn} phases, workflow.js has #{now}" unless drawn == now
  end

  # The section's identity is a hash of exactly what it emits: the body as
  # compose renders it (with name-based placeholder urls, since real urls
  # change per upload) plus each embedded SVG's digest. A visual marked
  # omitted is never embedded, and one with no url is emitted as an omission,
  # so a later render, reason change, or --first-pr changes the hash.
  def section_hash(visuals, omits: {}, first_pr: nil, urls: nil)
    embedded, notes = section_parts(visuals, urls || placeholder_urls(visuals), omits)
    body = section_lines(embedded, placeholder_urls(embedded), notes, first_pr)
    digests = embedded.map { |v| File.exist?(v.svg) ? Digest::SHA256.file(v.svg).hexdigest : 'missing' }
    Digest::SHA256.hexdigest((body + digests).join("\n"))[0, 16]
  end

  def placeholder_urls(visuals) = visuals.to_h { |v| [ v.name, { 'light' => "#{v.name}-light.png", 'dark' => "#{v.name}-dark.png" } ] }

  def url_for(urls, visual) = urls[visual.name] || urls[visual.name.to_sym]

  # [embedded visuals, {name => reason}]: omitted visuals are dropped, and a
  # selected visual with no url becomes an omission notice.
  def section_parts(visuals, urls, omits)
    notes = (omits || {}).to_h { |name, reason| [ name.to_s, reason ] }
    shown = visuals.reject { |v| notes.key?(v.name) }
    embedded, unlinked = shown.partition { |v| url_for(urls, v) }
    [ embedded, notes.merge(unlinked.to_h { |v| [ v.name, 'no uploaded image' ] }) ]
  end

  def svg_title(svg) = svg_source(svg)[%r{<title\b[^>]*>(.*?)</title>}m, 1]&.strip

  def png_paths(visual, manifest)
    entry = manifest&.dig('visuals', visual.name) || {}
    dir = File.dirname(visual.svg)
    [ File.join(dir, entry['light_png'] || "#{visual.name}-light.png"),
      File.join(dir, entry['dark_png'] || "#{visual.name}-dark.png") ]
  end

  # Pure: the marker-wrapped section from `urls` ({name => {light:, dark:}}).
  # Omitted visuals are never embedded; a visual with no url is listed as
  # omitted. `hash` defaults to the identity of exactly this output.
  def compose(visuals, urls:, hash: nil, omits: {}, first_pr: nil)
    embedded, notes = section_parts(visuals, urls, omits)
    hash ||= section_hash(visuals, omits: omits, first_pr: first_pr, urls: urls)
    ([ "#{START_PREFIX}#{hash} -->" ] + section_lines(embedded, urls, notes, first_pr) + [ END_MARK ]).join("\n")
  end

  def section_lines(embedded, urls, notes, first_pr)
    return [ "Plan visuals: see ##{first_pr}." ] if embedded.empty? && notes.empty? && first_pr

    lines = [ '## Plan visuals', '', 'Illustrative; plan.md wins on any conflict.', '' ]
    embedded.each do |v|
      u = url_for(urls, v)
      alt = (svg_title(v.svg) || v.name).gsub('"', '&quot;')
      lines << %(<picture><source media="(prefers-color-scheme: dark)" srcset="#{u['dark'] || u[:dark]}"><img src="#{u['light'] || u[:light]}" alt="#{alt}"></picture>)
      lines << ''
    end
    lines + notes.map { |name, reason| "#{name} omitted: #{reason}" }
  end

  def current_hash(body) = body.to_s[SECTION, 1]

  def splice(body, section)
    body = body.to_s
    return body.sub(SECTION) { section } if body.match?(SECTION)

    body.strip.empty? ? section : "#{body.rstrip}\n\n#{section}"
  end

  def unsplice(body) = "#{body.to_s.sub(SECTION, '').rstrip}\n"

  def repo_args(repo) = repo ? [ '--repo', repo ] : []

  def settled?(gh, pr, repo = nil)
    out, ok = gh.run('gh', 'pr', 'view', pr.to_s, '--json', 'mergeStateStatus,statusCheckRollup', *repo_args(repo))
    return [ false, 'could not read the PR state' ] unless ok

    data = JSON.parse(out)
    return [ false, "mergeStateStatus is #{data['mergeStateStatus']}" ] unless data['mergeStateStatus'] == 'CLEAN'

    pending = Array(data['statusCheckRollup']).reject do |c|
      SETTLED_CONCLUSIONS.include?(c['conclusion'].to_s.upcase) || SETTLED_CONCLUSIONS.include?(c['state'].to_s.upcase)
    end
    pending.empty? ? [ true, nil ] : [ false, "#{pending.size} check(s) not green" ]
  rescue JSON::ParserError
    [ false, 'could not parse the PR state' ]
  end

  def pr_facts(gh, pr, repo)
    out, ok = gh.run('gh', 'pr', 'view', pr.to_s, '--json', 'files,title,headRefName', *repo_args(repo))
    data = ok ? JSON.parse(out) : {}
    { files: Array(data['files']).map { |f| f['path'] }, title: data['title'].to_s, branch: data['headRefName'].to_s }
  rescue JSON::ParserError
    { files: [], title: '', branch: '' }
  end

  # Post outcome: `code` is the CLI exit status, `lines` what it prints.
  Outcome = Data.define(:code, :lines)

  class Poster
    def initialize(plan_dir, pr:, gh: Gh.new, uploader: nil, repo: nil)
      @plan_dir = plan_dir
      @pr = pr
      @gh = gh
      @repo = repo
      @uploader = uploader || ChangeScreenshotUpload.new(repo: repo)
    end

    def post(phase: nil, omits: {}, first_pr: nil, dry_run: false, require_settled: false)
      refusal = require_settled && unsettled_reason
      return Outcome.new(code: 4, lines: [ "not settled: #{refusal}" ]) if refusal

      manifest = PlanVisuals.manifest(@plan_dir)
      picked = PlanVisuals.select(@plan_dir, phase: phase)
      omits = omits.dup
      kept = picked[:visuals].reject { |v| omits.key?(v.name) }
      visuals, missing = kept.partition { |v| PlanVisuals.png_paths(v, manifest).all? { |p| File.exist?(p) } }
      missing.each { |v| omits[v.name] = 'PNG not rendered' }
      return clear(dry_run) if picked[:visuals].empty? && !picked[:link_back]

      link = picked[:link_back] ? first_pr : nil
      hash = PlanVisuals.section_hash(kept, omits: omits, first_pr: link)
      body, ok = @gh.run('gh', 'pr', 'view', @pr.to_s, '--json', 'body', '--jq', '.body', *PlanVisuals.repo_args(@repo))
      return Outcome.new(code: 3, lines: [ 'could not read the PR body' ]) unless ok
      return Outcome.new(code: 0, lines: [ 'unchanged' ]) if PlanVisuals.current_hash(body) == hash

      return Outcome.new(code: 0, lines: [ 'would post', PlanVisuals.compose(visuals, urls: PlanVisuals.placeholder_urls(visuals), hash: hash, omits: omits, first_pr: link) ]) if dry_run

      urls = upload(visuals, manifest)
      return Outcome.new(code: 3, lines: [ "upload failed, PR body left unchanged: #{@uploader.degradation_reason}" ]) unless urls

      section = PlanVisuals.compose(visuals, urls: urls, hash: hash, omits: omits, first_pr: link)
      edit(PlanVisuals.splice(body, section)) or return Outcome.new(code: 3, lines: [ 'gh pr edit failed' ])
      Outcome.new(code: 0, lines: [ "posted #{visuals.size} visual(s)", render_warning(section) ].compact)
    end

    private

    # Nothing is selected any more: remove a section an earlier post left,
    # and only no-op when there is none.
    def clear(dry_run)
      body, ok = @gh.run('gh', 'pr', 'view', @pr.to_s, '--json', 'body', '--jq', '.body', *PlanVisuals.repo_args(@repo))
      return Outcome.new(code: 3, lines: [ 'could not read the PR body' ]) unless ok
      return Outcome.new(code: 0, lines: [ 'nothing to post' ]) unless PlanVisuals.current_hash(body)
      return Outcome.new(code: 0, lines: [ 'would remove the plan visuals section' ]) if dry_run

      edit(PlanVisuals.unsplice(body)) or return Outcome.new(code: 3, lines: [ 'gh pr edit failed' ])
      Outcome.new(code: 0, lines: [ 'removed the plan visuals section' ])
    end

    def unsettled_reason
      ok, why = PlanVisuals.settled?(@gh, @pr, @repo)
      ok ? nil : why
    end

    # SS-1: every upload or none. A partial set returns nil, so no edit runs.
    def upload(visuals, manifest)
      paths = visuals.flat_map { |v| PlanVisuals.png_paths(v, manifest) }
      results = @uploader.upload_all(paths)
      return nil unless results.size == paths.size && results.all?(&:uploaded?)

      visuals.zip(results.each_slice(2)).to_h { |v, (light, dark)| [ v.name, { light: light.url, dark: dark.url } ] }
    end

    def edit(body)
      Tempfile.create([ 'plan-visuals', '.md' ]) do |file|
        file.write(body)
        file.flush
        _, ok = @gh.run('gh', 'pr', 'edit', @pr.to_s, '--body-file', file.path, *PlanVisuals.repo_args(@repo))
        ok
      end
    end

    # GitHub's sanitizer decides whether <picture> survives; warn, never fail.
    def render_warning(section)
      return nil unless section.include?('<picture>')

      argv = [ 'gh', 'api', '/markdown', '-f', "text=#{section}", '-f', 'mode=gfm' ]
      argv += [ '-f', "context=#{@repo}" ] if @repo
      html, ok = @gh.run(*argv)
      return 'warning: could not verify rendering via gh api /markdown' unless ok
      return nil if html.include?('<picture') && html.include?('<source')

      'warning: GitHub stripped <picture>; fall back to a light-only <img>'
    end
  end

  module CLI
    USAGE = <<~TXT
      usage: plan_visuals.rb select  <plan_dir> [--phase N]
             plan_visuals.rb check   <plan_dir> --pr N [--phase N] [--repo owner/name]
             plan_visuals.rb compose <plan_dir> --pr N --urls JSON [--phase N]
             plan_visuals.rb post    <plan_dir> --pr N [--phase N] [--first-pr N] [--omit name=reason ...]
                                     [--repo owner/name] [--dry-run] [--require-settled]
    TXT

    def self.run(argv, out: $stdout, gh: Gh.new, uploader: nil)
      verb, dir, *rest = argv
      opts = parse(rest)
      return usage(out) unless dir && File.directory?(dir) && %w[select check compose post].include?(verb)
      return usage(out) if verb != 'select' && !opts[:pr]

      send("run_#{verb}", dir, opts, out, gh, uploader)
    end

    def self.usage(out)
      out.puts(USAGE)
      2
    end

    def self.run_select(dir, opts, out, _gh, _uploader)
      picked = PlanVisuals.select(dir, phase: opts[:phase])
      out.puts(JSON.generate(visuals: picked[:visuals].map { |v| { name: v.name, type: v.type, phases: v.phases } },
                             link_back: picked[:link_back]))
      0
    end

    def self.run_check(dir, opts, out, gh, _uploader)
      facts = PlanVisuals.pr_facts(gh, opts[:pr], opts[:repo])
      manifest = PlanVisuals.manifest(dir)
      plan_text = File.read(File.join(dir, 'plan.md'))
      results = PlanVisuals.select(dir, phase: opts[:phase])[:visuals].map do |v|
        PlanVisuals.check_visual(v, plan_dir: dir, pr: facts, phase: opts[:phase], manifest: manifest, plan_text: plan_text)
      end
      out.puts(JSON.pretty_generate(results))
      verdicts = results.map { |r| r[:verdict] }
      return 1 if verdicts.include?('drift')

      verdicts.include?('inconclusive') ? 2 : 0
    end

    def self.run_compose(dir, opts, out, _gh, _uploader)
      visuals = PlanVisuals.select(dir, phase: opts[:phase])[:visuals]
      out.puts(PlanVisuals.compose(visuals, urls: JSON.parse(opts[:urls] || '{}'), omits: opts[:omit] || {}))
      0
    end

    def self.run_post(dir, opts, out, gh, uploader)
      outcome = Poster.new(dir, pr: opts[:pr], gh: gh, uploader: uploader, repo: opts[:repo])
                      .post(phase: opts[:phase], omits: opts[:omit], first_pr: opts[:first_pr],
                            dry_run: opts[:dry_run], require_settled: opts[:require_settled])
      out.puts(outcome.lines)
      outcome.code
    end

    def self.parse(args)
      opts = { omit: {} }
      args = args.dup
      until args.empty?
        case (token = args.shift)
        when '--pr' then opts[:pr] = args.shift
        when '--phase' then opts[:phase] = args.shift.to_i
        when '--first-pr' then opts[:first_pr] = args.shift
        when '--repo' then opts[:repo] = args.shift
        when '--urls' then opts[:urls] = args.shift
        when '--omit'
          name, reason = args.shift.to_s.split('=', 2)
          opts[:omit][name] = reason.to_s
        when '--dry-run' then opts[:dry_run] = true
        when '--require-settled' then opts[:require_settled] = true
        else opts[:unknown] = token
        end
      end
      opts
    end
  end
end

exit(PlanVisuals::CLI.run(ARGV)) if __FILE__ == $PROGRAM_NAME
