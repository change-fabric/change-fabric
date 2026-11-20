#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'digest'
require 'fileutils'
require 'open3'
require 'base64'
require 'rbconfig'
require 'tmpdir'
require_relative 'incident_store'
require_relative 'sensitive_terms'
require_relative 'change_suite'
require_relative 'change_docker'

# The client-facing half of cf:incident: a plain-language summary and a
# screenshot evidence PDF, drafted for a human to send. Nothing here sends
# anything. A draft moves draft, scanned, roasted, ready, and each state is
# bound to the SHA-256 of the file's current bytes, so any later edit drops it
# back to draft. Drafts go to CF_INCIDENT_CLIENT_DIR (a template with <client>
# and <date>; never inside a git work tree), else to <incident dir>/report/.
# Receipts live in <incident dir>/report/manifest.json, never in the client dir.
module IncidentReport
  SCHEMA = 'cf.incident-report-1'
  DRAFTS = %w[summary pdf].freeze
  # The checkout's skill references, else the installed skill's (the script
  # runs from ~/.claude/cf/bin, where there is no skills/ beside it).
  TEMPLATES = [ File.expand_path('../skills/incident/reference', __dir__),
                File.join(Dir.home, '.claude', 'skills', 'cf:incident', 'reference') ]
              .find { |dir| File.file?(File.join(dir, 'evidence-pdf.typ')) } || File.expand_path('../skills/incident/reference', __dir__)
  ROAST_SCRIPT = File.join(__dir__, 'roast.rb')
  # roast.rb refuses a review with no audience or no purpose outcome.
  AUDIENCE = "the client's stakeholders reading an incident report"
  PURPOSES = {
    'summary' => [ 'State what was affected and for how long', 'State what was fixed and what now prevents a repeat' ],
    'pdf' => [ 'Show that production now serves the fixed version, read-only', 'Show which pages and viewports were checked' ]
  }.freeze
  SECTIONS = %w[impact timeline fix prevention].freeze
  # The pinned OCR image: tesseract 5.5.4. Runs with no network.
  OCR_IMAGE = ChangeDocker::TESSERACT_IMAGE

  # Patterns for a secret that must never reach a client. Each is a kind name
  # and a regexp; a hit reports the kind only, never the matched text.
  SECRET_PATTERNS = {
    'aws access key' => /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
    'provider token' => /\b(?:ghp_|gho_|ghs_|github_pat_|sk-|xox[abp]-)[A-Za-z0-9_-]{10,}/,
    'private key' => /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    'bearer token' => /\bBearer\s+[A-Za-z0-9._~+\/-]{16,}/,
    'jwt' => /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
    'credential assignment' => /\b(?:password|passwd|secret|api[_-]?key|token)\s*[:=]\s*\S{6,}/i
  }.freeze

  class Error < StandardError; end

  module_function

  def sha256_file(path) = Digest::SHA256.file(path).hexdigest

  def sha256(text) = Digest::SHA256.hexdigest(text)

  # The default process runner: [combined output, success]. Tests inject a fake.
  class Shell
    def run(argv, env: {}, chdir: nil)
      opts = chdir ? { chdir: chdir } : {}
      out, status = Open3.capture2e(env, *argv, **opts)
      [ out, status.success? ]
    rescue SystemCallError => e
      [ e.message, false ]
    end
  end

  # Secret and sensitive-term scan over named texts. Returns the hit list as
  # `{ source:, kind: }`; a sensitive term's text is never echoed.
  module Scan
    module_function

    def hits(texts, terms: SensitiveTerms.load)
      texts.flat_map do |source, text|
        found = terms.empty? ? [] : SensitiveTerms.matched([ text ], terms).map { { source: source, kind: 'sensitive term' } }
        found + SECRET_PATTERNS.select { |_kind, re| text.match?(re) }.map { |kind, _| { source: source, kind: kind } }
      end
    end
  end

  # OCR in the pinned container. `runner` is called with a PNG path and returns
  # [text, ok]; the default runs tesseract with no network and the image mounted
  # read-only. Unavailable (no docker, a failed run) is a result, not a crash.
  class Ocr
    def initialize(runner: nil)
      @runner = runner || method(:container)
    end

    def read(path) = @runner.call(path)

    def container(path)
      return [ 'docker unavailable', false ] unless ChangeDocker.available?

      out, status = ChangeDocker.run(network: 'none', image: OCR_IMAGE, mounts: { File.dirname(path) => { target: '/in', readonly: true } },
                                     args: [ "/in/#{File.basename(path)}", 'stdout', '-l', 'eng' ])
      [ out.lines.grep_v(/\AEstimating resolution/).join, status.success? ]
    end
  end

  # Read-only prod capture. The browser module intercepts every request: any
  # method but GET or HEAD is aborted, any host off the allowlist is aborted,
  # and a navigation that lands off-host fails the capture. Routes must come
  # from a cf:qa suite's read-only cases; a route outside that list is refused.
  module Capture
    DEFAULT_VIEWPORTS = { 'desktop' => [ 1440, 900 ], 'mobile' => [ 390, 844 ] }.freeze
    DEFAULT_MASKS = [ 'input[type=email]', 'input[type=tel]', 'input[type=password]', '[autocomplete*=token]',
                      '[data-sensitive]', '[data-cf-mask]' ].freeze
    READ_ONLY_TAG = 'read-only'

    class Refused < Error; end

    module_function

    # The paths a suite's read-only cases `goto`. Cases without the read-only tag add none.
    def allowed_routes(suite_files)
      suite_files.flat_map do |file|
        ChangeSuite.load_file(file).cases.select { |c| c.tags.include?(READ_ONLY_TAG) }.flat_map { |c| gotos(c.steps) }
      rescue ChangeSuite::Error => e
        raise Refused, e.message
      end.uniq
    end

    def gotos(steps)
      Array(steps).filter_map do |step|
        next unless step.is_a?(Hash) && step.key?('goto')

        spec = step['goto']
        url = spec.is_a?(Hash) ? spec['url'] : spec
        route_of(url.to_s)
      end
    end

    # A route as path plus query: a full URL is reduced to it.
    def route_of(url)
      uri = URI.parse(url)
      "#{uri.path.to_s.empty? ? '/' : uri.path}#{uri.query ? "?#{uri.query}" : ''}"
    rescue URI::InvalidURIError
      url
    end

    def check!(routes:, allowed:, session:, session_approved_by:)
      raise Refused, 'capture needs a read-only cf:qa suite: pass --suite FILE (cases tagged read-only)' if allowed.empty?

      bad = routes.reject { |route| allowed.include?(route) }
      raise Refused, "route not in the read-only suite allowlist: #{bad.join(', ')}" unless bad.empty?
      return if session.nil? || !session_approved_by.to_s.strip.empty?

      raise Refused, "session #{session.inspect} needs --session-approved-by <who approved it>; no admin or privileged session without it"
    end

    def viewports(spec)
      names = spec.to_s.split(',').map(&:strip).reject(&:empty?)
      names = DEFAULT_VIEWPORTS.keys if names.empty?
      names.to_h do |name|
        custom = name.match(/\A([\w-]+)=(\d+)x(\d+)\z/)
        next [ custom[1], [ custom[2].to_i, custom[3].to_i ] ] if custom

        [ name, DEFAULT_VIEWPORTS.fetch(name) { raise Refused, "unknown viewport #{name.inspect}; use #{DEFAULT_VIEWPORTS.keys.join(', ')} or name=WxH" } ]
      end
    end

    # The browserless /function module. Policy lives in `decide`, which the
    # tests drive with a fake page under node.
    def module_source(base:, hosts:, routes:, viewports:, masks:, cookie: nil)
      cfg = { base: base, base_host: URI.parse(base).host, hosts: hosts, routes: routes, masks: masks, cookie: cookie,
              viewports: viewports.map { |name, (w, h)| { name: name, width: w, height: h } } }
      MODULE_JS.sub('__CFG__') { JSON.generate(cfg) }
    end

    MODULE_JS = <<~'JS'
      export default async ({ page }) => {
        const cfg = __CFG__;
        const SAFE = ['GET', 'HEAD'];
        const hostOk = (u) => cfg.hosts.includes(u.host);
        const blocked = [];
        const shots = [];
        const failed = [];
        let offHostNav = null;
        const decide = (method, rawUrl, isNav) => {
          let u;
          try { u = new URL(rawUrl); } catch (e) { return { allow: false, reason: 'unparseable url' }; }
          if (!SAFE.includes(String(method).toUpperCase())) return { allow: false, reason: 'method ' + method };
          if (['data:', 'blob:', 'about:'].includes(u.protocol)) return { allow: true };
          if (!['http:', 'https:'].includes(u.protocol)) return { allow: false, reason: 'protocol ' + u.protocol };
          if (!hostOk(u)) return { allow: false, reason: 'off-host ' + u.host, nav: isNav };
          return { allow: true };
        };
        await page.setRequestInterception(true);
        page.on('request', (req) => {
          const verdict = decide(req.method(), req.url(), req.isNavigationRequest());
          if (verdict.allow) return cfg.cookie && new URL(req.url()).host === cfg.base_host
            ? req.continue({ headers: { ...req.headers(), Cookie: cfg.cookie } }) : req.continue();
          blocked.push({ method: req.method(), url: req.url().split('?')[0], reason: verdict.reason });
          if (verdict.nav) offHostNav = verdict.reason;
          return req.abort('blockedbyclient');
        });
        await page.evaluateOnNewDocument(() => {
          window.WebSocket = class { constructor() { throw new Error('blocked: read-only capture'); } };
          window.EventSource = class { constructor() { throw new Error('blocked: read-only capture'); } };
        });
        const mask = (selectors) => {
          const re = [/[\w.+-]+@[\w-]+\.[\w.-]+/g, /\+?\d[\d ().-]{8,}\d/g, /\b(?:eyJ|ghp_|sk-|xox[abp]-)[\w.-]{10,}/g];
          for (const el of document.querySelectorAll(selectors.join(','))) {
            el.value = '';
            el.style.setProperty('background', '#000', 'important');
            el.style.setProperty('color', '#000', 'important');
            el.style.setProperty('background-image', 'none', 'important');
            el.style.setProperty('filter', 'brightness(0)', 'important');
            for (const child of el.querySelectorAll('*')) child.style.setProperty('visibility', 'hidden', 'important');
          }
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            n.nodeValue = re.reduce((text, r) => text.replace(r, '[masked]'), n.nodeValue);
          }
        };
        for (const vp of cfg.viewports) {
          for (const route of cfg.routes) {
            offHostNav = null;
            try {
              await page.setViewport({ width: vp.width, height: vp.height, deviceScaleFactor: 1 });
              const resp = await page.goto(cfg.base + route, { waitUntil: 'networkidle2', timeout: 30000 });
              if (offHostNav) throw new Error('redirect left the allowed hosts: ' + offHostNav);
              const final = new URL(page.url());
              if (!hostOk(final)) throw new Error('final url is off-host: ' + final.host);
              const finalRoute = final.pathname + final.search;
              if (!cfg.routes.includes(finalRoute)) throw new Error('redirected to an unlisted route: ' + final.pathname);
              if (resp && resp.status() >= 400) throw new Error('http status ' + resp.status());
              await page.evaluate(mask, cfg.masks);
              const png = await page.screenshot({ fullPage: true, encoding: 'base64' });
              shots.push({ route, viewport: vp.name, png, final_url: final.origin + final.pathname });
            } catch (e) {
              failed.push({ route, viewport: vp.name, reason: offHostNav ? 'redirect left the allowed hosts: ' + offHostNav : String(e.message || e) });
            }
          }
        }
        return { data: { shots, blocked, failed }, type: 'application/json' };
      };
    JS

    # Runs the module in `browser` (anything with run_function) and writes the
    # screens only when every route and viewport succeeded. Returns the
    # captures.json hash.
    def run(browser:, dir:, base:, hosts:, routes:, viewports:, masks:, at:, version:, cookie: nil)
      code = module_source(base: base, hosts: hosts, routes: routes, viewports: viewports, masks: masks, cookie: cookie)
      result = browser.run_function(code, launch_args: [])
      failed = Array(result['failed'])
      unless failed.empty?
        raise Refused, "capture failed: #{failed.map { |f| "#{f['viewport']} #{f['route']}: #{f['reason']}" }.join('; ')}"
      end

      write(dir, result, base: base, at: at, version: version)
    end

    def write(dir, result, base:, at:, version:)
      screens = File.join(dir, 'screens')
      FileUtils.mkdir_p(screens)
      shots = Array(result['shots']).map do |shot|
        file = "#{shot['viewport']}-#{route_slug(shot['route'])}-#{IncidentReport.sha256(shot['route'])[0, 8]}.png"
        File.binwrite(File.join(screens, file), Base64.decode64(shot['png']))
        { 'file' => file, 'route' => shot['route'], 'viewport' => shot['viewport'], 'final_url' => shot['final_url'],
          'sha256' => IncidentReport.sha256_file(File.join(screens, file)) }
      end
      record = { 'captured_at' => Time.parse(at).utc.iso8601, 'host' => URI.parse(base).host, 'version' => version.to_s,
                 'read_only' => true, 'shots' => shots, 'blocked' => Array(result['blocked']) }
      File.write(File.join(screens, 'captures.json'), "#{JSON.pretty_generate(record)}\n")
      record
    end

    def route_slug(route)
      slug = route.to_s.gsub(/[^A-Za-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
      slug.empty? ? 'root' : slug
    end
  end

  # One incident's report: drafts, receipts and the finalize binding.
  class Report
    attr_reader :store, :id, :dir

    def initialize(store:, id:, shell: Shell.new, ocr: Ocr.new, client_template: ENV.fetch('CF_INCIDENT_CLIENT_DIR', nil),
                   known_roots: ENV.fetch('CF_KNOWN_REPO_ROOTS', nil), repo_path: nil, terms: nil)
      @store = store
      @id = store.resolve(id)
      @dir = store.path(@id)
      @shell = shell
      @ocr = ocr
      @client_template = client_template
      @known_roots = [ repo_path ].compact + known_roots.to_s.split(':').reject(&:empty?)
      @terms = terms
    end

    def report_dir = File.join(dir, 'report')
    def screens_dir = File.join(dir, 'evidence', 'screens')
    def manifest_path = File.join(report_dir, 'manifest.json')
    def final_path = File.join(report_dir, 'report.json')

    def manifest
      File.file?(manifest_path) ? JSON.parse(File.read(manifest_path)) : { 'schema' => SCHEMA, 'id' => id, 'drafts' => {}, 'scan' => {}, 'roast' => {}, 'ocr' => {} }
    end

    def save(data)
      FileUtils.mkdir_p(report_dir)
      tmp = "#{manifest_path}.tmp#{Process.pid}"
      File.write(tmp, "#{JSON.pretty_generate(data)}\n")
      File.rename(tmp, manifest_path)
    end

    def incident = store.read(id)

    # --- destination --------------------------------------------------------

    def destination(m, at)
      return m['dest'] if m['dest']

      dest = if @client_template.to_s.strip.empty?
               File.join(report_dir, 'out')
      else
               expand_template(@client_template, at)
      end
      IncidentStore.assert_outside_git!(dest, @known_roots, 'client destination') unless @client_template.to_s.strip.empty?
      dest
    end

    def expand_template(template, at)
      client = IncidentStore.segment(incident['client'].to_s)
      raise Error, 'the client destination needs <client>, but this incident has no client: create it with --client' if template.include?('<client>') && client.empty?

      # One directory per incident: two incidents for a client on one day must not share paths.
      File.join(File.expand_path(template.gsub('<client>', client).gsub('<date>', Time.parse(at).utc.strftime('%m%d%y%a').downcase)), id)
    end

    # --- draft ---------------------------------------------------------------

    # sections: { 'impact' => text, ... }. Renders the summary, and the PDF
    # when screenshots were captured.
    def draft(at:, sections:, title:)
      missing = SECTIONS - sections.keys.select { |k| !sections[k].to_s.strip.empty? }
      raise Error, "draft needs every section: missing #{missing.join(', ')}" unless missing.empty?

      m = manifest
      dest = destination(m, at)
      FileUtils.mkdir_p(dest)
      m['dest'] = dest
      summary = File.join(dest, 'client-summary.md')
      File.write(summary, render_summary(title, at, sections))
      m['drafts']['summary'] = { 'path' => summary }
      draft_pdf(m, dest, title)
      # A human exception approved the old bytes, never the new ones.
      %w[scan roast].each { |key| m[key] = {} }
      %w[ocr_attestation accepted_below_bar].each { |key| m.delete(key) }
      FileUtils.rm_f(final_path)
      save(m)
      store.append(id, at: at, actor: 'report', text: "client report drafted into #{File.basename(dest)}")
      m
    end

    def render_summary(title, at, sections)
      template = File.read(File.join(TEMPLATES, 'client-summary-template.md')).gsub(/<!--.*?-->\n*/m, '')
      values = sections.merge('title' => title, 'date' => Time.parse(at).utc.strftime('%Y-%m-%d'))
      "#{template.gsub(/\{\{(\w+)\}\}/) { values.fetch(Regexp.last_match(1)).to_s.strip }.strip}\n"
    end

    def draft_pdf(m, dest, title)
      captures_file = File.join(screens_dir, 'captures.json')
      unless File.file?(captures_file)
        m['drafts'].delete('pdf')
        m.delete('pages')
        return
      end

      captures = JSON.parse(File.read(captures_file))
      work = File.join(report_dir, 'work')
      require_typst!
      FileUtils.rm_rf(work)
      FileUtils.mkdir_p(work)
      stage_work(work, captures, title)
      pdf = File.join(dest, 'evidence.pdf')
      pages = File.join(report_dir, 'pages')
      FileUtils.rm_rf(pages)
      FileUtils.mkdir_p(pages)
      build!([ 'typst', 'compile', File.join(work, 'evidence.typ'), pdf ])
      build!([ 'typst', 'compile', '--format', 'png', '--ppi', '110', File.join(work, 'evidence.typ'), File.join(pages, 'page-{0p}.png') ])
      files = Dir[File.join(pages, 'page-*.png')].sort
      raise Error, 'the evidence PDF rendered no pages' if files.empty?

      m['drafts']['pdf'] = { 'path' => pdf }
      m['pages'] = { 'pdf_sha256' => IncidentReport.sha256_file(pdf), 'captures_sha256' => IncidentReport.sha256_file(captures_file), 'files' => files.map { |f| { 'file' => f, 'sha256' => IncidentReport.sha256_file(f) } } }
    end

    def stage_work(work, captures, title)
      shots = captures['shots'].map do |shot|
        FileUtils.cp(File.join(screens_dir, shot['file']), File.join(work, shot['file']))
        { 'file' => shot['file'], 'caption' => "#{shot['viewport']}: #{shot['route']}" }
      end
      footer = "production #{captures['version']} - #{captures['host']} - captured #{captures['captured_at'][0, 10]} - read-only"
      File.write(File.join(work, 'evidence.json'), JSON.pretty_generate('title' => title, 'footer' => footer, 'shots' => shots))
      FileUtils.cp(File.join(TEMPLATES, 'evidence-pdf.typ'), File.join(work, 'evidence.typ'))
    end

    def require_typst!
      _out, ok = @shell.run([ 'typst', '--version' ])
      raise Error, 'typst is not installed or not on PATH: install typst (https://typst.app, `brew install typst`) to build the evidence PDF' unless ok
    end

    def build!(argv)
      out, ok = @shell.run(argv)
      raise Error, "#{argv.first(2).join(' ')} failed: #{out.lines.last(3).join.strip}" unless ok
    end

    # --- ocr -----------------------------------------------------------------

    # OCRs each captured screenshot. `unavailable` is recorded, not raised: the
    # draft then needs `finalize --attest-no-ocr`.
    def ocr_screens(at:)
      captures = JSON.parse(File.read(File.join(screens_dir, 'captures.json')))
      out_dir = File.join(report_dir, 'ocr', 'screens')
      FileUtils.mkdir_p(out_dir)
      m = manifest
      m['ocr'] = { 'status' => 'ok', 'at' => Time.parse(at).utc.iso8601, 'screens' => {} }
      captures['shots'].each do |shot|
        path = File.join(screens_dir, shot['file'])
        text, ok = @ocr.read(path)
        unless ok
          m['ocr'].merge!('status' => 'unavailable', 'reason' => text.to_s.lines.first.to_s.strip)
          next
        end
        File.write(File.join(out_dir, "#{shot['file']}.txt"), text)
        m['ocr']['screens'][shot['file']] = { 'sha256' => IncidentReport.sha256_file(path), 'text_sha256' => IncidentReport.sha256(text) }
      end
      save(m)
      m['ocr']
    end

    # --- scan ----------------------------------------------------------------

    def scan(at:)
      m = manifest
      DRAFTS.each do |name|
        draft = m['drafts'][name] or next
        sha = IncidentReport.sha256_file(draft['path'])
        texts, notes = scan_texts(m, name, draft)
        hits = Scan.hits(texts, terms: @terms || SensitiveTerms.load)
        m['scan'][name] = { 'content_sha256' => sha, 'ok' => hits.empty? && notes.none? { |n| n[:fatal] }, 'hits' => hits,
                            'notes' => notes.map { |n| n[:text] }, 'at' => Time.parse(at).utc.iso8601 }
      end
      raise Error, 'nothing to scan: run draft first' if m['scan'].empty?

      save(m)
      m['scan']
    end

    def scan_texts(m, name, draft)
      return [ { 'client-summary.md' => File.read(draft['path']) }, [] ] if name == 'summary'

      texts = {}
      notes = []
      captures_file = File.join(screens_dir, 'captures.json')
      # The PDF and its pages show the captures it was built from; a recapture needs a redraft.
      stale = m.dig('pages', 'captures_sha256') != IncidentReport.sha256_file(captures_file)
      notes << { text: 'screenshots were recaptured after the PDF was drafted: run draft again', fatal: true } if stale
      captures = JSON.parse(File.read(captures_file))
      texts['evidence captions'] = captures['shots'].map { |s| "#{s['viewport']}: #{s['route']}" }.join("\n") + "\n#{captures['host']} #{captures['version']}"
      unavailable = (m['ocr'] || {})['status'] == 'unavailable'
      # Whatever OCR did read is scanned, even when another screenshot failed.
      captures['shots'].each do |shot|
        text = ocr_text(m, shot)
        texts["ocr #{shot['file']}"] = text if text
        next if text

        notes << (unavailable ? { text: "OCR unavailable for #{shot['file']}: finalize needs --attest-no-ocr", fatal: false }
                              : { text: "no current OCR for #{shot['file']}: run ocr", fatal: true })
      end
      [ texts, notes ]
    end

    def ocr_text(m, shot)
      rec = m.dig('ocr', 'screens', shot['file'])
      file = File.join(report_dir, 'ocr', 'screens', "#{shot['file']}.txt")
      return nil unless rec && File.file?(file) && rec['sha256'] == shot['sha256'] && IncidentReport.sha256_file(File.join(screens_dir, shot['file'])) == shot['sha256']

      File.read(file)
    end

    # --- roast ---------------------------------------------------------------

    def roast_target(repo_dir)
      out, ok = @shell.run([ RbConfig.ruby, ROAST_SCRIPT, 'settings', '--repo', repo_dir ])
      target = out[/target\s+(\d+(?:\.\d+)?)/, 1]
      raise Error, "roast settings failed: #{out.strip}" unless ok && target

      target.to_f
    end

    def roast(at:, repo_dir: Dir.pwd, max_usd: nil)
      m = manifest
      raise Error, 'nothing to roast: run draft first' if m['drafts'].empty?

      names = DRAFTS.select { |name| m['drafts'][name] }
      names.each do |name|
        sha = IncidentReport.sha256_file(m['drafts'][name]['path'])
        scan = m['scan'][name]
        raise Error, "#{name} is not scanned at its current bytes: run scan first (scan and roast come after drafting)" unless scan && scan['content_sha256'] == sha && scan['ok']
      end
      target = roast_target(repo_dir)
      names.each do |name|
        draft = m['drafts'][name]
        sha = IncidentReport.sha256_file(draft['path'])
        m['roast'][name] = roast_one(name, draft, sha, m, repo_dir: repo_dir, at: at, target: target, max_usd: max_usd)
      end
      save(m)
      m['roast']
    end

    def roast_one(name, draft, sha, m, repo_dir:, at:, target:, max_usd:)
      out_dir = File.join(report_dir, 'roast', name)
      FileUtils.mkdir_p(out_dir)
      brief = File.join(out_dir, 'brief.txt')
      File.write(brief, brief_for(name))
      argv = [ RbConfig.ruby, ROAST_SCRIPT, '--repo', repo_dir, '--brief', brief, '--out-dir', out_dir, '--kind', 'doc' ]
      argv += [ '--audience', AUDIENCE ] + PURPOSES.fetch(name).flat_map { |outcome| [ '--purpose', outcome ] }
      argv += [ '--max-usd', max_usd.to_s ] if max_usd
      argv += name == 'summary' ? [ '--text', draft['path'] ] : roast_pages(m, sha).flat_map { |page| [ '--shot', page ] }
      out, ok = @shell.run(argv)
      raise Error, "roast failed for #{name}: #{out.lines.last(3).join.strip}" unless ok

      receipt(out_dir, sha, target, at)
    end

    def roast_pages(m, pdf_sha)
      pages = m['pages']
      raise Error, 'the PDF has no rendered pages: redraft' unless pages && pages['pdf_sha256'] == pdf_sha

      pages['files'].map { |f| f['file'] }
    end

    def brief_for(name)
      what = name == 'summary' ? 'a plain-language incident summary' : 'an evidence PDF of read-only production screenshots'
      "Review #{what} that an engineer will send to a client after a production incident. It must be plain, accurate, " \
        'free of internal detail and blame, and show the client what happened and what changed.'
    end

    def receipt(out_dir, sha, target, at)
      latest = Dir[File.join(out_dir, 'round-*.json')].max_by { |f| f[/round-(\d+)\.json\z/, 1].to_i } or raise Error, "roast wrote no round file in #{out_dir}"
      critic = JSON.parse(File.read(latest))
      { 'content_sha256' => sha, 'score' => critic['score'], 'p0_open' => Array(critic['issues']).count { |i| i['priority'] == 'P0' },
        'target' => target, 'round_file' => latest, 'at' => Time.parse(at).utc.iso8601 }
    end

    # --- state ---------------------------------------------------------------

    def state(name, m = manifest)
      draft = m['drafts'][name]
      return nil unless draft && File.file?(draft['path'])

      sha = IncidentReport.sha256_file(draft['path'])
      scan = m['scan'][name]
      return 'draft' unless scan && scan['content_sha256'] == sha && scan['ok']

      roast = m['roast'][name]
      return 'scanned' unless roast_passes?(roast, sha, m)

      final = final_record
      final && final.dig('drafts', name, 'content_sha256') == sha && final.dig('drafts', name, 'ready') ? 'ready' : 'roasted'
    end

    def roast_passes?(roast, sha, m)
      return false unless roast && roast['content_sha256'] == sha

      roast['p0_open'].zero? && (roast['score'] >= roast['target'] || m['accepted_below_bar'])
    end

    def final_record = File.file?(final_path) ? JSON.parse(File.read(final_path)) : nil

    def states
      m = manifest
      DRAFTS.filter_map { |name| (s = state(name, m)) && [ name, s ] }.to_h
    end

    # --- finalize ------------------------------------------------------------

    # Binds each draft's bytes, scan and roast receipt into report.json. Returns
    # [report, problems]; problems is empty only when every draft is ready.
    def finalize(at:, attest_no_ocr: nil, accept_below_bar: nil)
      m = manifest
      raise Error, 'nothing to finalize: run draft first' if m['drafts'].empty?

      m['accepted_below_bar'] = { 'reason' => accept_below_bar.to_s.strip, 'at' => Time.parse(at).utc.iso8601 } unless accept_below_bar.to_s.strip.empty?
      m['ocr_attestation'] = { 'reason' => attest_no_ocr.to_s.strip, 'at' => Time.parse(at).utc.iso8601 } unless attest_no_ocr.to_s.strip.empty?
      problems = []
      drafts = DRAFTS.filter_map { |name| (d = m['drafts'][name]) && [ name, finalize_draft(name, d, m, problems) ] }.to_h
      report = { 'schema' => SCHEMA, 'id' => id, 'finalized_at' => Time.parse(at).utc.iso8601, 'dest' => m['dest'], 'drafts' => drafts,
                 'ocr_attestation' => m['ocr_attestation'], 'accepted_below_bar' => m['accepted_below_bar'], 'ready' => problems.empty? }
      File.write(final_path, "#{JSON.pretty_generate(report)}\n")
      save(m)
      [ report, problems ]
    end

    def finalize_draft(name, draft, m, problems)
      sha = IncidentReport.sha256_file(draft['path'])
      mine = []
      scan = m['scan'][name]
      mine << "#{name}: not scanned at its current bytes" unless scan && scan['content_sha256'] == sha && scan['ok']
      roast = m['roast'][name]
      mine << "#{name}: no roast receipt matches the current bytes" unless roast && roast['content_sha256'] == sha
      mine << "#{name}: roast score #{roast['score']} is below #{roast['target']} or a P0 is open (accept with --accept-below-bar)" if roast && roast['content_sha256'] == sha && !roast_passes?(roast, sha, m)
      mine.concat(final_pdf_check(m, sha)) if name == 'pdf'
      problems.concat(mine)
      { 'path' => draft['path'], 'content_sha256' => sha, 'scan' => scan, 'roast' => roast, 'ready' => mine.empty? }
    end

    # OCRs the compiled PDF's pages and scans that text, so what a client sees
    # is what was scanned. Without OCR, only an attestation lets it through.
    def final_pdf_check(m, sha)
      pages = m['pages']
      return [ 'pdf: no rendered pages bound to this PDF; redraft' ] unless pages && pages['pdf_sha256'] == sha

      reads = pages['files'].map { |page| [ page['file'], *@ocr.read(page['file']) ] }
      readable = reads.select { |_file, _text, ok| ok }
      texts = readable.to_h { |file, text, _ok| [ "pdf page #{File.basename(file)}", text ] }
      hits = Scan.hits(texts, terms: @terms || SensitiveTerms.load)
      problems = hits.map { |h| "pdf: #{h[:kind]} in #{h[:source]}" }
      if readable.size < reads.size
        m['ocr']['final_pdf'] = { 'status' => 'unavailable', 'pdf_sha256' => sha, 'hits' => hits }
        problems << 'pdf: OCR is unavailable for some pages; attest with --attest-no-ocr "<reason>"' unless m['ocr_attestation']
        return problems
      end
      m['ocr']['final_pdf'] = { 'status' => 'ok', 'pdf_sha256' => sha, 'hits' => hits }
      problems
    end
  end

  # --- command line ----------------------------------------------------------

  class Cli
    USAGE = <<~TEXT
      usage: incident_report.rb <command> --repo <slug> --id <id> [options]
        capture --url https://HOST --routes /a,/b --suite FILE [--suite FILE] [--viewports desktop,mobile|name=WxH]
                [--allow-host H] [--mask-selectors CSS,CSS] [--version V] [--session NAME --session-approved-by WHO] --at ISO
        draft --at ISO --title T --impact-file F --timeline-file F --fix-file F --prevention-file F
        ocr --at ISO
        scan --at ISO
        roast --at ISO [--repo-dir DIR] [--max-usd N]
        finalize --at ISO [--attest-no-ocr REASON] [--accept-below-bar REASON]
        status
      A client report is drafted, scanned and roasted, and only a human sends it. Nothing here sends.
    TEXT

    def initialize(argv, out: $stdout, err: $stderr, shell: Shell.new, ocr: Ocr.new, browser: nil, env: ENV)
      @argv = argv.dup
      @out = out
      @err = err
      @shell = shell
      @ocr = ocr
      @browser = browser
      @env = env
    end

    def run
      command = @argv.shift
      return usage(0) if %w[-h --help help].include?(command)
      return usage(2) unless %w[capture draft ocr scan roast finalize status].include?(command)

      @opts = parse(@argv)
      @report = build_report
      send("cmd_#{command}")
    rescue Error, IncidentStore::Invalid, ChangeSuite::Error, KeyError, Errno::ENOENT => e
      @err.puts("incident_report: #{e.message}")
      1
    end

    private

    def build_report
      store = IncidentStore.new(repo: opt('repo'), repo_path: @opts['repo-path'])
      Report.new(store: store, id: opt('id'), shell: @shell, ocr: @ocr, repo_path: @opts['repo-path'],
                 client_template: @env['CF_INCIDENT_CLIENT_DIR'], known_roots: @env['CF_KNOWN_REPO_ROOTS'])
    end

    def opt(name) = @opts[name].to_s.strip.then { |v| v.empty? ? raise(Error, "--#{name} is required") : v }

    def cmd_capture
      base = opt('url').sub(%r{/+\z}, '')
      raise Capture::Refused, 'capture only reads an https production URL' unless base.start_with?('https://')

      routes = opt('routes').split(',').map(&:strip).reject(&:empty?)
      Capture.check!(routes: routes, allowed: Capture.allowed_routes(Array(@opts['suite'])), session: @opts['session'],
                     session_approved_by: @opts['session-approved-by'])
      record = Capture.run(browser: browser_for, dir: File.join(@report.dir, 'evidence'), base: base, routes: routes, at: opt('at'),
                           hosts: [ URI.parse(base).host ] + Array(@opts['allow-host']), viewports: Capture.viewports(@opts['viewports']),
                           masks: Capture::DEFAULT_MASKS + @opts['mask-selectors'].to_s.split(',').map(&:strip).reject(&:empty?),
                           version: @opts['version'] || @report.incident.dig('hotfix', 'serving_version'), cookie: session_cookie)
      @report.store.append(@report.id, at: opt('at'), actor: 'report', text: "captured #{record['shots'].size} read-only screenshot(s) of #{record['host']}")
      @out.puts("captured #{record['shots'].size} screenshot(s), #{record['blocked'].size} request(s) blocked")
      0
    end

    def session_cookie
      return nil unless @opts['session']

      @env["CF_INCIDENT_SESSION_COOKIE_#{@opts['session'].upcase.gsub(/[^A-Z0-9]/, '_')}"] || raise(Capture::Refused, 'the approved session has no cookie in the environment')
    end

    def browser_for
      return @browser if @browser

      raise Error, 'docker is unavailable: capture needs the browserless container' unless ChangeDocker.available?

      LiveBrowser.new
    end

    def cmd_draft
      sections = SECTIONS.to_h { |name| [ name, File.read(opt("#{name}-file")) ] }
      m = @report.draft(at: opt('at'), sections: sections, title: opt('title'))
      @out.puts("drafted #{m['drafts'].keys.join(', ')} into #{m['dest']}")
      0
    end

    def cmd_ocr
      result = @report.ocr_screens(at: opt('at'))
      @out.puts("ocr #{result['status']}: #{result['screens'].size} screenshot(s)")
      result['status'] == 'ok' ? 0 : 1
    end

    def cmd_scan
      result = @report.scan(at: opt('at'))
      result.each do |name, scan|
        @out.puts("scan #{name}: #{scan['ok'] ? 'clean' : 'blocked'}")
        scan['hits'].each { |hit| @out.puts("  #{hit[:kind] || hit['kind']} in #{hit[:source] || hit['source']}") }
        scan['notes'].each { |note| @out.puts("  #{note}") }
      end
      result.values.all? { |scan| scan['ok'] } ? 0 : 1
    end

    def cmd_roast
      @report.roast(at: opt('at'), repo_dir: @opts['repo-dir'] || Dir.pwd, max_usd: @opts['max-usd']).each do |name, r|
        @out.puts("roast #{name}: #{r['score']}/10 (target #{r['target']}), P0 open #{r['p0_open']}")
      end
      0
    end

    def cmd_finalize
      report, problems = @report.finalize(at: opt('at'), attest_no_ocr: @opts['attest-no-ocr'], accept_below_bar: @opts['accept-below-bar'])
      report['drafts'].each { |name, d| @out.puts("#{name}: #{d['ready'] ? 'ready' : 'not ready'}") }
      problems.each { |problem| @out.puts("  #{problem}") }
      problems.empty? ? 0 : 1
    end

    def cmd_status
      @report.states.each { |name, state| @out.puts("#{name}: #{state}") }
      0
    end

    def usage(code)
      (code.zero? ? @out : @err).puts(USAGE)
      code
    end

    def parse(args)
      opts = {}
      queue = args.dup
      until queue.empty?
        token = queue.shift
        raise Error, "unexpected argument #{token.inspect}" unless token.start_with?('--')

        name, inline = token[2..].split('=', 2)
        value = inline
        value = queue.shift if value.nil? && !queue.empty? && !queue.first.start_with?('--')
        value = value.to_s
        %w[suite allow-host].include?(name) ? (opts[name] ||= []) << value : opts[name] = value
      end
      opts
    end
  end

  # The live browserless container for capture: no network of its own, only the
  # outbound reach a prod page needs. Built lazily so tests never start docker.
  class LiveBrowser
    def run_function(code, launch_args: [])
      ChangeDocker.with_network(nil) do |network|
        ChangeDocker.with_browserless(network: network.name) { |session| session.run_function(code, launch_args: launch_args) }
      end
    end
  end
end

exit(IncidentReport::Cli.new(ARGV).run) if $PROGRAM_NAME == __FILE__
