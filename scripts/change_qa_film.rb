#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'yaml'
require_relative 'browserless_pdf'
require_relative 'cf_project_identity'
require_relative 'change_config'
require_relative 'change_docker'
require_relative 'change_flow_compiler'
require_relative 'change_lane_browserless'
require_relative 'change_lane_testcases'
require_relative 'change_local_tls'
require_relative 'change_suite_render'
require_relative 'change_testcases_evidence'
require_relative 'change_testcases_report'
require_relative 'secret_intake/staging_store'

# `cf:qa film`: films one flag-gated flow on a deployed environment, signed in
# as a persona, and leaves UAT evidence (an MP4, report.html and report.pdf, a
# JUnit file, and a pass/fail checklist) with no hand-written suite.
#
#   change_qa_film.rb probe --url URL --persona NAME [--steps draft.yml]
#   change_qa_film.rb run   --url URL --persona NAME --flag KEY --draft draft.yml
#                           [--flag-probe PATH --flag-expect TEXT | --flag-selector SEL]
#                           [--out DIR] [--save-suite PATH]
#
# `probe` is the drafting loop the calling agent session iterates with: it
# signs in as the persona, runs the draft's steps so far, and prints each
# step's result plus a compact snapshot of the page it ended on (title, url,
# headings, and the visible interactive elements with a selector for each), so
# the next step can be written against what is really there. No model runs in
# here; the session that called it writes the draft.
#
# `run` films the draft. The flag check is the first step: a GET of the probe
# path (`{flag}` replaced by the key) whose body must contain the expected
# text, or, with no probe, a selector that is visible only with the flag on.
# The case then runs through the testcases lane itself (persona login and
# session seeding, video, acceptance grading, evidence dir), so what is filmed
# is exactly what a committed suite would replay. It records no gate: a film
# is evidence for a person, not a release verdict.
#
# Persona credentials are the env names the persona's login fields read. A
# name not set in the environment is taken from the project's cf secret store
# (staged with cf:secret-intake), into this process only. Values are never
# printed, and the printed results are the compiler's redacted view.
module ChangeQaFilm
  Error = Class.new(StandardError)

  SUITE = 'film'
  SNAPSHOT_LIMIT = 120

  # The page as the drafting session needs it: what is on screen and how to
  # point at it. Input values are never read, so a typed credential cannot
  # leak through a snapshot.
  SNAPSHOT_JS = <<~JS
    const limit = #{SNAPSHOT_LIMIT};
    const clean = (s) => (s || "").replace(/\\s+/g, " ").trim().slice(0, 80);
    const visible = (el) => { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el);
      return r.width > 0 && r.height > 0 && cs.visibility !== "hidden" && cs.display !== "none"; };
    const pick = (el) => {
      for (const attr of ["data-testid", "data-test", "data-cy"]) {
        const v = el.getAttribute(attr); if (v) return `[${attr}="${v}"]`;
      }
      if (el.id && /^[A-Za-z][\\w-]*$/.test(el.id)) return `#${el.id}`;
      const name = clean(el.getAttribute("aria-label") || el.innerText);
      if (name && !name.includes('"')) return `${el.tagName.toLowerCase()}:has-text("${name}")`;
      if (el.getAttribute("name")) return `${el.tagName.toLowerCase()}[name="${el.getAttribute("name")}"]`;
      return el.tagName.toLowerCase();
    };
    const query = 'a,button,input,select,textarea,summary,[role=button],[role=link],[role=tab],' +
      '[role=menuitem],[role=checkbox],[role=row],[data-testid],[data-test]';
    const elements = [...document.querySelectorAll(query)].filter(visible).slice(0, limit).map((el) => ({
      role: el.getAttribute("role") || el.tagName.toLowerCase(),
      name: clean(el.getAttribute("aria-label") || el.innerText || el.getAttribute("placeholder") || el.getAttribute("title")),
      selector: pick(el),
    }));
    const headings = [...document.querySelectorAll("h1,h2,h3")].filter(visible).map((h) => clean(h.innerText)).slice(0, 20);
    return { title: document.title, url: location.href, headings: headings, elements: elements };
  JS

  Context = Struct.new(:target_url, :browserless, :suite_select, :signoff, :logger, :run_id, :evidence_dir,
                       :commit, :exports, :video_budget_mb, keyword_init: true) do
    def log(message) = logger.call(message)
    def signoff? = false
  end

  module_function

  # --- pure parts -----------------------------------------------------------------

  # The flag check as declarative steps. A probe reads the flag from the app;
  # a selector proves it from what the persona can see.
  def flag_steps(flag:, probe: nil, expect: 'true', selector: nil)
    raise Error, '--flag is required' if flag.to_s.strip.empty?

    if probe && !probe.to_s.empty?
      path = probe.to_s.gsub('{flag}', flag.to_s)
      return [ { 'goto' => path }, { 'expect_text' => { 'selector' => 'body', 'contains' => expect.to_s } } ]
    end
    raise Error, "flag #{flag} needs --flag-probe PATH or --flag-selector SEL to confirm it is on" if selector.to_s.empty?

    [ { 'expect_visible' => selector.to_s } ]
  end

  # A draft file: `acceptance:` (the sentence a client would sign off on) and
  # `steps:`, each step one verb plus an optional `check:`, the checklist line
  # it proves. Returns [steps without check keys, checklist labels].
  def load_draft(path)
    raw = YAML.safe_load_file(path, aliases: false)
    raise Error, "#{path} is not a mapping with steps:" unless raw.is_a?(Hash) && raw['steps'].is_a?(Array)

    checks = []
    steps = raw['steps'].map do |step|
      raise Error, "#{path}: every step must be a mapping" unless step.is_a?(Hash)

      checks << step['check']&.to_s
      step.except('check')
    end
    { acceptance: raw['acceptance'].to_s, steps: steps, checks: checks }
  end

  # The persona's login as flow steps, for `probe`, which has no lane to log in
  # for it: each auth step's page, its fields, its submit and its wait.
  def login_steps(auth)
    auth.steps.flat_map do |step|
      list = []
      list << { 'goto' => step[:url] } unless step[:url].to_s.empty?
      step[:fields].each { |field| list << { 'fill' => login_fill(field) } }
      list << { 'click' => step[:submit_selector] } if step[:submit_selector]
      list << { 'wait_for' => { 'selector' => step[:wait_for_selector] } } if step[:wait_for_selector]
      list
    end
  end

  def login_fill(field)
    return { 'selector' => field[:selector], 'env' => field[:env] } if field[:env] && !field[:env].empty?
    return { 'selector' => field[:selector], 'code_source' => field[:code_source].transform_keys(&:to_s).compact } if field[:code_source]

    raise Error, "login field #{field[:selector]} names no env or code_source"
  end

  # The env names a persona's login reads.
  def secret_names(auth) = auth.steps.flat_map { |step| step[:fields].filter_map { |field| field[:env] } }.reject(&:empty?).uniq

  # Fills each name the environment lacks from `store` (anything answering
  # read(name)) into `env`. Returns the names neither had. Never logs a value.
  def resolve_secrets(names, env: ENV, store: nil)
    names.reject do |name|
      next true unless env[name].to_s.empty?

      value = store&.read(name)
      value = value&.chomp
      next false if value.nil? || value.empty?

      env[name] = value
      true
    end
  end

  # The case as filmed, one entry per step: { step:, check:, flag: }. It opens
  # on a page (the staging url when the draft names none). A probe flag check
  # runs first, since it navigates to the probe and the draft's opening goto
  # then leaves it; a selector flag check runs on the opening page.
  def plan(draft, flag, url, probe:)
    steps = opening_goto(draft[:steps], url)
    checks = steps.size == draft[:steps].size ? draft[:checks] : [ 'Open the page' ] + draft[:checks]
    body = steps.each_with_index.map { |step, index| { step: step, check: checks[index], flag: false } }
    flagged = flag.map { |step| { step: step, check: nil, flag: true } }
    probe ? flagged + body : body.first(1) + flagged + body.drop(1)
  end

  # One checklist line per filmed step under its `check:` label (or the
  # compiler's), the flag steps as one line, and the acceptance verdict last.
  # `results` are the attempt's step records.
  def checklist(entries:, labels:, results:, flag:, acceptance:, verdict:, status:)
    by_index = Array(results).to_h { |record| [ record['index'].to_i, record ] }
    flag_records = entries.each_index.select { |index| entries[index][:flag] }.map { |index| by_index[index] }
    lines = [ "# UAT checklist: #{status == 'pass' ? 'PASS' : 'FAIL'}", '' ]
    entries.each_with_index do |entry, index|
      if entry[:flag]
        next unless index == entries.index { |other| other[:flag] }

        lines << line(state_of(flag_records), "Flag `#{flag}` is on", flag_records.compact.find { |r| !r['ok'] })
      else
        text = entry[:check].to_s.empty? ? labels[index] : entry[:check]
        lines << line(state_of([ by_index[index] ]), text, by_index[index])
      end
    end
    lines << line(verdict.to_s == 'pass' ? 'pass' : (verdict || 'not graded').to_s, "Acceptance: #{acceptance}")
    "#{lines.join("\n")}\n"
  end

  def state_of(records)
    return 'not run' if records.any?(&:nil?)

    records.all? { |record| record['ok'] } ? 'pass' : 'fail'
  end

  def line(state, text, record = nil)
    text = "#{text} (#{record['error']})" if record && !record['ok'] && record['error']
    "- [#{state == 'pass' ? 'x' : ' '}] #{state.upcase}: #{text}"
  end

  # --- CLI ------------------------------------------------------------------------

  def main(argv)
    command = argv.shift
    options = parse(argv)
    case command
    when 'probe' then probe(options)
    when 'run' then film(options)
    else usage
    end
  rescue Error, ChangeFlowCompiler::Error, ChangeConfig::ConfigError, ChangeSuiteRender::Error, ArgumentError => e
    warn "film error: #{e.message}"
    1
  end

  def parse(argv)
    options = { add_hosts: [], launch_args: [] }
    flags = { '--url' => :url, '--persona' => :persona, '--flag' => :flag, '--flag-probe' => :flag_probe,
              '--flag-expect' => :flag_expect, '--flag-selector' => :flag_selector, '--draft' => :draft,
              '--steps' => :draft, '--out' => :out, '--save-suite' => :save_suite, '--profile' => :profile,
              '--change-md' => :change_md, '--case-id' => :case_id }
    until argv.empty?
      arg = argv.shift
      key = flags[arg]
      raise ArgumentError, "unknown option #{arg}" unless key

      value = argv.shift
      raise ArgumentError, "#{arg} needs a value" if value.nil?

      options[key] = value
    end
    raise ArgumentError, '--url is required' if options[:url].to_s.empty?

    options
  end

  def probe(options)
    auth = persona_auth(options)
    require_secrets(auth)
    draft = opening_goto(options[:draft] ? load_draft(options[:draft])[:steps] : [], options[:url])
    steps = (auth ? login_steps(auth) : []) + draft + [ { 'eval' => { 'script' => SNAPSHOT_JS } } ]
    compiler = ChangeFlowCompiler.new(steps, base_url: options[:url], timeout_ms: 30_000, viewport: lane_viewport(options))
    result = with_session(options) { |session| session.run_function(compiler.function_module, launch_args: launch_args(options)) }
    puts JSON.pretty_generate(probe_view(result, auth ? login_steps(auth).size : 0))
    0
  end

  # The draft as it will be filmed: opening on a page, the staging url itself
  # when the draft does not name one.
  def opening_goto(steps, url)
    first = steps.first
    first.is_a?(Hash) && first.key?('goto') ? steps : [ { 'goto' => url } ] + steps
  end

  # Drops the login's own steps from the print, and lifts the snapshot out of
  # the final eval record.
  def probe_view(result, login_count)
    records = Array(result.is_a?(Hash) ? result['steps'] : nil)
    login = records.first(login_count)
    snapshot = records.last if records.last && records.last['raw'] && records.last['ok']
    body = records.drop(login_count)
    body = body[0...-1] if snapshot
    { login: login.all? { |record| record['ok'] } ? 'ok' : 'failed', login_error: login.find { |r| !r['ok'] }&.dig('error'),
      steps: body.map { |record| record.slice('index', 'label', 'ok', 'error', 'found') },
      snapshot: snapshot&.dig('value') }.compact
  end

  def film(options)
    draft = load_draft(options.fetch(:draft) { raise Error, '--draft is required' })
    raise Error, 'the draft needs an acceptance: sentence' if draft[:acceptance].strip.empty?

    auth = persona_auth(options)
    require_secrets(auth)
    entries = plan(draft, flag_steps_for(options), options[:url], probe: !options[:flag_probe].to_s.empty?)
    out = File.expand_path(options[:out] || File.join(Dir.pwd, 'qa-film', Time.now.utc.strftime('%Y%m%dT%H%M%SZ')))
    FileUtils.mkdir_p(out)
    case_id = options[:case_id] || "#{slug(options[:flag])}-#{slug(options[:persona] || 'anonymous')}"
    suite_path = File.join(out, "#{SUITE}.cf-testcases.yml")
    yaml = ChangeSuiteRender.suite_yaml(steps: entries.map { |entry| entry[:step] }, suite: SUITE, id: case_id,
                                        acceptance: draft[:acceptance], persona: options[:persona], tags: [ 'film' ])
    File.write(suite_path, yaml)
    run_dir = run_lane(options, suite_path, out)
    summary = summarize(run_dir, options, entries, draft[:acceptance])
    if options[:save_suite] && summary[:status] == 'pass'
      save_suite(options[:save_suite], yaml.sub(/\A(---\n)?suite: #{SUITE}\n/) { "#{Regexp.last_match(1)}suite: #{suite_id(options[:save_suite])}\n" })
    end
    puts JSON.pretty_generate(summary)
    summary[:status] == 'pass' ? 0 : 3
  end

  def run_lane(options, suite_path, out)
    run_id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}"
    evidence = ChangeTestcasesEvidence.prepare(out, run_id)
    lane_config = testcases_lane(options).merge('suites' => [ suite_path ], 'base_url' => options[:url],
                                                'tags' => [], 'gate_tags' => [], 'parallel' => 1)
    with_session(options, mounts: { evidence => ChangeTestcasesEvidence::MOUNT }) do |session|
      context = Context.new(target_url: options[:url], browserless: session, suite_select: [ SUITE ],
                            logger: ->(message) { warn message }, run_id: run_id, evidence_dir: evidence,
                            commit: nil, exports: %w[video], video_budget_mb: 512)
      ChangeLaneTestcases.new(lane_config, context).run.each { |finding| warn "[film] #{finding.status}: #{finding.detail}" }
    end
    write_reports(evidence, options)
    evidence
  end

  def write_reports(dir, options)
    return unless File.exist?(File.join(dir, ChangeTestcasesEvidence::RESULTS_FILE))

    report = ChangeTestcasesReport.new(run_dir: dir, ledger: File.join(dir, 'history.jsonl'))
    report.write
    BrowserlessPdf.render(dir)
  rescue StandardError => e
    warn "[film] report export failed (#{options[:url]}): #{e.message}"
  end

  def summarize(run_dir, options, entries, acceptance)
    record = read_jsonl(File.join(run_dir, ChangeTestcasesEvidence::RESULTS_FILE)).first || {}
    result_path = record['evidence_dir'] && File.join(record['evidence_dir'], 'result.json')
    results = result_path && File.exist?(result_path) ? JSON.parse(File.read(result_path))['steps'] : []
    labels = ChangeFlowCompiler.new(entries.map { |entry| entry[:step] }, base_url: options[:url]).labels
    status = record['status'] || 'fail'
    checklist_path = File.join(run_dir, 'checklist.md')
    File.write(checklist_path, checklist(entries: entries, labels: labels, results: results, flag: options[:flag],
                                         acceptance: acceptance, verdict: record['acceptance_verdict'], status: status))
    { status: status, checklist: checklist_path, video: video_path(run_dir), report: existing(run_dir, 'report.html'),
      pdf: existing(run_dir, 'report.pdf'), junit: existing(run_dir, 'junit.xml'), run_dir: run_dir,
      saved_suite: status == 'pass' ? options[:save_suite] : nil }.compact
  end

  def flag_steps_for(options)
    flag_steps(flag: options[:flag], probe: options[:flag_probe], expect: options[:flag_expect] || 'true',
               selector: options[:flag_selector])
  end

  def video_path(run_dir)
    exports = File.join(run_dir, 'exports.json')
    from_exports = File.exist?(exports) ? JSON.parse(File.read(exports)).dig('video')&.values&.find { |e| e['path'] }&.dig('path') : nil
    from_exports || Dir.glob(File.join(run_dir, '**', '*.mp4')).first
  end

  def existing(dir, name) = File.exist?(File.join(dir, name)) ? File.join(dir, name) : nil

  def read_jsonl(path) = File.exist?(path) ? File.readlines(path).map { |row| JSON.parse(row) } : []

  # `qa/reports.cf-testcases.yml` saves as suite `reports`.
  def suite_id(path) = slug(File.basename(path.to_s).sub(/\..*\z/, '')).then { |id| id.empty? ? SUITE : id }

  # Writes the passing case as a suite file. Never over an existing file: the
  # rendered YAML is printed for a hand merge instead.
  def save_suite(path, yaml)
    path = File.expand_path(path)
    if File.exist?(path)
      warn "[film] #{path} exists; not overwritten. Append this case by hand:\n#{yaml}"
      return
    end
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, yaml)
  end

  # --- config and secrets ---------------------------------------------------------

  def change_config(options)
    path = options[:change_md] || File.join(Dir.pwd, 'CHANGE.md')
    return nil unless options[:change_md] || options[:profile] || File.exist?(path)

    @change_config ||= {}
    @change_config[[ path, options[:profile] ]] ||= ChangeConfig.load(path, profile: options[:profile])
  end

  def testcases_lane(options)
    config = change_config(options)
    config ? config.lane('testcases') : ChangeConfig::LaneConfig.new('testcases', {}, Dir.pwd)
  end

  # The persona's AuthConfig, nil for anonymous. `default` is the lane's auth:.
  def persona_auth(options)
    name = options[:persona].to_s
    return nil if name.empty? || name == 'anonymous'

    lane = testcases_lane(options)
    raw = name == 'default' ? lane['auth'] : (lane['personas'] || {}).transform_keys(&:to_s)[name]
    raise Error, "persona '#{name}' is not defined under lanes.testcases.personas in CHANGE.md" unless raw.is_a?(Hash)

    ChangeLaneBrowserless::AuthConfig.new(raw)
  end

  def require_secrets(auth)
    return unless auth

    missing = resolve_secrets(secret_names(auth), store: secret_store)
    raise Error, "persona credentials not set: #{missing.join(', ')}; stage them with cf:secret-intake" unless missing.empty?
  end

  def secret_store
    SecretIntake::StagingStore.new(project: CfProjectIdentity.for(Dir.pwd))
  rescue StandardError
    nil
  end

  def lane_viewport(options)
    raw = testcases_lane(options)['viewport']
    raw.is_a?(Hash) ? raw.slice('width', 'height') : { 'width' => 1280, 'height' => 800 }
  end

  def launch_args(options) = Array(testcases_lane(options)['launch_args']).map(&:to_s)

  def with_session(options, mounts: {}, &)
    raise Error, 'docker is unavailable; cannot film' unless ChangeDocker.available?

    boot = change_config(options)&.boot
    add_hosts = boot ? boot.add_hosts : []
    tls = boot&.ignore_https_errors ? ChangeLocalTls.allowed_hosts(options[:url], add_hosts) : nil
    ChangeDocker.with_network(nil) do |net|
      ChangeDocker.with_browserless(network: net.name, add_hosts: add_hosts, local_tls_hosts: tls, mounts: mounts, &)
    end
  end

  def slug(text) = text.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')

  def usage
    warn 'usage: change_qa_film.rb probe --url URL [--persona NAME] [--steps draft.yml] [--profile NAME]'
    warn '       change_qa_film.rb run --url URL --persona NAME --flag KEY --draft draft.yml'
    warn '         [--flag-probe PATH [--flag-expect TEXT] | --flag-selector SEL] [--out DIR] [--save-suite PATH]'
    2
  end
end

exit(ChangeQaFilm.main(ARGV)) if __FILE__ == $PROGRAM_NAME
