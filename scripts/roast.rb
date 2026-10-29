# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'net/http'
require 'openssl'
require 'optparse'
require 'uri'
require_relative 'design_config'
require_relative 'roast_kind'
require_relative 'sensitive_terms'
require_relative 'walkthrough_cache'
require_relative 'walkthrough_env'

# cf:roast: the deterministic critic-call CLI. One paid call per round sends the
# screenshots, the brief, and the prior rounds' history to an OpenAI vision model
# and gets back structured JSON (score, prioritized issues, a 30-second-test
# verdict). Claude's own accept/rebut/apply step is the skill's job, not this
# script's. Rounds are logged to a roast/ directory (round-N.json, round-N.md),
# keyed by content so a repeat of the same inputs costs nothing and needs no key.
module Roast
  # gpt-6.1-sol: image input, Responses API, Structured Outputs, per
  # https://developers.openai.com/api/docs/models/gpt-6.1-sol (checked 2026-10-28).
  DEFAULT_MODEL = 'gpt-6.1-sol'
  MODEL = ENV.fetch('CF_ROAST_MODEL', DEFAULT_MODEL)
  RESPONSES_URL = 'https://api.openai.com/v1/responses'
  DEFAULT_CEILING_USD = 0.5
  DEFAULT_TARGET = 9
  DEFAULT_CAP = 4
  PRIORITIES = %w[P0 P1 P2].freeze
  BLOCKING = %w[P0 P1].freeze
  DEFAULT_OUT_DIR = 'roast'
  VERDICTS = %w[pass partial fail].freeze
  # Rough planning figures, not a quote: USD per million tokens (input, output),
  # tokens per image, and the output cap. The estimate stays conservative.
  # Prices: standard tier, https://developers.openai.com/api/docs/pricing (checked 2026-10-28).
  PRICE_PER_MTOK = { input: 2.0, output: 10.0 }.freeze
  IMAGE_TOKENS = 1500
  MAX_OUTPUT_TOKENS = 4000
  MIME = { '.png' => 'image/png', '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg', '.webp' => 'image/webp' }.freeze
  USAGE = 'usage: roast.rb --brief FILE (--shot IMG... | --text FILE...) [--allow-sensitive] [--history DIR] [--out-dir DIR] [--round N] ' \
          '[--max-usd N] [--model NAME] [--cache DIR] [--transcript FILE] [--estimate-only] ' \
          '[--storyboard FILE] [--kind explainer|promo|demo|email|doc|pr|post] [--audience TEXT] [--purpose OUTCOME]... | roast.rb infer [--storyboard FILE] [--text FILE]... | roast.rb decide --out-dir DIR [--target N] [--cap N] | roast.rb settings [--repo DIR]; ' \
          'flags win over the storyboard review object, which wins over change_config.design.roast in CHANGE.md (--repo DIR, default the working directory)'

  KINDS = ChangeSchema::REVIEW_KINDS

  SYSTEM_PROMPT = <<~TEXT
    You are a harsh, specific critic of a UX, a narrated walkthrough, or a piece of writing (an email,
    a doc, a PR description, a post). Roast it: no praise padding, no vague taste talk. Every issue
    names where it is (the screen or scene for visuals, a quoted phrase or paragraph number for text),
    the concrete problem the stated audience would hit, and a concrete fix the author can apply. Prioritize: P0 blocks the audience from the stated
    purpose, P1 badly hurts clarity or trust, P2 is polish.

    The artifact declares what it is: a review contract gives its kind, its audience, and its purpose,
    a list of outcomes a viewer must be able to state afterward. Judge it against that contract, not
    against a generic product page. Do not dock points for something the contract does not ask for.

    Score 0 to 10 against the stated audience. Anchors: 3 means it fails its audience, 5 means it has a
    blocking flaw for this audience, 7 means it serves its audience with clear fixes left, 9 means ship
    it to this audience.

    Run the purpose test: could the stated audience, after watching or reading, state each listed
    purpose outcome? Report one purpose_test entry per outcome, in order, with a verdict of pass,
    partial, or fail and the evidence (a screen, a cue, or the gap). thirty_second_test is the overall
    verdict of that test: fail if any outcome fails, partial if any is partial, else pass.

    Kind guidance. explainer: it teaches the audience something; it needs no call to action, install
    link, or product naming unless a purpose outcome asks for it. promo: keep the what, who, and
    next-step test in addition to the purpose outcomes; a missing call to action is a real flaw.
    demo: it must show the thing running; a described but unshown capability is a flaw.
    email: is the ask clear, is the deadline stated, and is it clear why it matters to this reader;
    judge length, tone, and anything that could land badly. doc: can the reader find what they need
    from the headings alone, is the order the reader's rather than the author's, and is every claim
    concrete and checkable. pr: does the title and opening say what changed and why, is the test plan
    something a reviewer can run, and are risks and follow-ups named. post: does the first line earn the
    read, is there one clear point and one next step, and is the tone right for the audience and venue.
    For text, the purpose outcomes are what the reader must be able to state or do after reading.

    Production facts you cannot see. The frames are sampled keyframes, not the full video, so do not
    infer motion or timing gaps from them alone. Captions may ship as sidecar srt or vtt files rather
    than burned into the frames. When a narration transcript or caption cues are supplied, do not
    report missing captions because none show in the keyframes.

    You are given earlier rounds. Do not repeat an issue that was fixed; hold the line on one the
    author rebutted weakly; accept a rebuttal that is sound and say so in the summary.
    When a narration transcript with captions is given, critique it too: name an issue's where
    as the scene id or the cue it concerns.
  TEXT

  SCHEMA = {
    type: 'object', additionalProperties: false,
    required: %w[score summary issues thirty_second_test purpose_test],
    properties: {
      score: { type: 'number' },
      summary: { type: 'string' },
      issues: {
        type: 'array',
        items: {
          type: 'object', additionalProperties: false, required: %w[priority where problem fix],
          properties: {
            priority: { type: 'string', enum: PRIORITIES },
            where: { type: 'string' }, problem: { type: 'string' }, fix: { type: 'string' }
          }
        }
      },
      thirty_second_test: {
        type: 'object', additionalProperties: false, required: %w[verdict reason],
        properties: { verdict: { type: 'string', enum: VERDICTS }, reason: { type: 'string' } }
      },
      purpose_test: {
        type: 'array',
        items: {
          type: 'object', additionalProperties: false, required: %w[outcome verdict reason],
          properties: { outcome: { type: 'string' }, verdict: { type: 'string', enum: VERDICTS }, reason: { type: 'string' } }
        }
      }
    }
  }.freeze

  class UsageError < StandardError; end
  class CeilingError < StandardError; end
  class RequestError < StandardError; end
  # The review contract (audience, purpose) did not resolve; a RequestError so a
  # caller that already skips a failed round skips this one with the same message.
  class ReviewError < RequestError; end
  # A text input matched the user's sensitive-terms list and was not allowed.
  class SensitiveError < StandardError; end

  module_function

  # Where an issue sits: `where` (screen, scene, quoted phrase, paragraph), or
  # `screen`, the field earlier rounds and walkthrough response files carry.
  def location(item) = (item['where'] || item['screen']).to_s

  def mime_for(path) = MIME.fetch(File.extname(path).downcase) { raise UsageError, "unsupported image type: #{path}" }

  # Prior rounds from DIR: each round-N.json (the critic) with its optional
  # round-N.response.json (Claude's accept/rebut), ordered by N.
  def load_history(dir)
    return [] unless dir && File.directory?(dir)

    Dir.glob(File.join(dir, 'round-*.json')).filter_map do |path|
      n = File.basename(path)[/\Around-(\d+)\.json\z/, 1]
      next unless n

      response = File.join(dir, "round-#{n}.response.json")
      { round: n.to_i, critic: JSON.parse(File.read(path)),
        response: File.file?(response) ? JSON.parse(File.read(response)) : nil }
    end.sort_by { |h| h[:round] }
  end

  # The review contract from its three sources, by key: a flag wins over the
  # storyboard's review object, which wins over change_config.design.roast.
  # Refuses (ReviewError) when audience or purpose resolves empty, or the kind is
  # unknown. A kind no source names stays nil and the critic applies none.
  def resolve_review(flags: {}, storyboard: nil, config: {})
    sources = [ flags, storyboard.is_a?(Hash) ? storyboard.transform_keys(&:to_s).transform_keys(&:to_sym) : {}, config ]
    pick = ->(key) { sources.map { |h| h[key] }.find { |v| !blank_review?(v) } }
    review = { kind: pick.call(:kind), audience: pick.call(:audience)&.to_s&.strip, purpose: Array(pick.call(:purpose)).map { |p| p.to_s.strip }.reject(&:empty?) }
    check_review!(review)
    review
  end

  def blank_review?(value) = value.nil? || value.to_s.strip.empty? || (value.respond_to?(:empty?) && value.empty?)

  def check_review!(review)
    raise ReviewError, "roast refused: no audience (set --audience, storyboard review.audience, or change_config.design.roast.audience)" unless review[:audience]
    raise ReviewError, "roast refused: no purpose (set --purpose, or storyboard review.purpose as a list of outcomes)" if review[:purpose].empty?
    return if review[:kind].nil? || KINDS.include?(review[:kind])

    raise ReviewError, "roast refused: kind must be one of #{KINDS.join(', ')}, got #{review[:kind].inspect}"
  end

  def review_text(review)
    return nil unless review

    outcomes = review[:purpose].each_with_index.map { |p, i| "#{i + 1}. #{p}" }
    [ "Review contract:", "Kind: #{review[:kind] || '(not declared; apply no kind-specific requirement)'}",
     "Audience: #{review[:audience]}", "Purpose outcomes a viewer must be able to state afterward:", *outcomes ].join("\n")
  end

  def next_round(dir)
    (load_history(dir).map { |h| h[:round] }.max || 0) + 1
  end

  # `transcript` is optional narration and caption text the critic reads next to
  # the frames; it joins the key only when present, so frame-only keys are stable.
  def request_key(brief:, shots:, history:, round:, texts: [], transcript: nil, review: nil, model: MODEL)
    WalkthroughCache.key({ model: model, brief: brief, round: round, history: history,
                           shots: shots.map { |s| Digest::SHA256.file(s).hexdigest } }
                           .merge(texts.empty? ? {} : { texts: texts.map { |t| Digest::SHA256.file(t).hexdigest } })
                           .merge(transcript ? { transcript: transcript } : {}).merge(review ? { review: review } : {}))
  end

  def estimate(brief:, shots:, history:, texts: [], transcript: nil, review: nil)
    chars = SYSTEM_PROMPT.size + texts.sum { |t| File.size(t) } + brief.size + JSON.generate(history).size + transcript.to_s.size + review_text(review).to_s.size
    input = (chars / 4) + (shots.size * IMAGE_TOKENS)
    usd = ((input * PRICE_PER_MTOK[:input]) + (MAX_OUTPUT_TOKENS * PRICE_PER_MTOK[:output])) / 1_000_000.0
    { usd: usd.round(2), tokens: input }
  end

  def user_text(brief, history, round, shots, texts: [], transcript: nil, review: nil)
    past = history.map do |h|
      "Round #{h[:round]} critic:\n#{JSON.pretty_generate(h[:critic])}\n" \
        "Round #{h[:round]} author response:\n#{h[:response] ? JSON.pretty_generate(h[:response]) : '(none recorded)'}"
    end
    [ "Round #{round}.", review_text(review), "Brief:\n#{brief}",
     (shots.empty? ? nil : "Screens, in order: #{shots.map { |s| File.basename(s) }.join(', ')}"),
     *texts.each_with_index.map { |t, i| "Text under review (#{i + 1} of #{texts.size}, #{File.basename(t)}):\n#{File.read(t).strip}" },
     (transcript ? "Narration transcript and captions:\n#{transcript}" : nil),
     (past.empty? ? 'No earlier rounds.' : "Earlier rounds:\n#{past.join("\n\n")}") ].compact.join("\n\n")
  end

  # The pure request description: the URL and the JSON body, no auth or cache key.
  def build_request(brief:, shots:, history:, round:, texts: [], transcript: nil, review: nil, model: MODEL)
    images = shots.map do |s|
      { type: 'input_image', image_url: "data:#{mime_for(s)};base64,#{Base64.strict_encode64(File.binread(s))}" }
    end
    text = { type: 'input_text', text: user_text(brief, history, round, shots, texts: texts, transcript: transcript, review: review) }
    { url: RESPONSES_URL,
      body: { model: model, max_output_tokens: MAX_OUTPUT_TOKENS,
              input: [ { role: 'system', content: SYSTEM_PROMPT }, { role: 'user', content: [ text, *images ] } ],
              text: { format: { type: 'json_schema', name: 'roast', strict: true, schema: SCHEMA } } } }
  end

  def post(request, http)
    uri = URI(request[:url])
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{WalkthroughEnv.openai_key!}"
    req['Content-Type'] = 'application/json'
    req.body = JSON.generate(request[:body])
    response = transport { (http || default_http(uri)).request(req) }
    raise RequestError, "roast request failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  # Network faults (timeouts, resets, TLS, DNS) surface as RequestError so
  # optional-roast callers can skip the critique instead of aborting.
  TRANSPORT_ERRORS = [ Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse ].freeze

  def transport
    yield
  rescue *TRANSPORT_ERRORS => e
    raise RequestError, "roast request failed: #{e.class}"
  end

  def default_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 300
    http
  end

  # Pulls the model's JSON out of a Responses body and validates its shape.
  def parse_critic(body)
    text = output_text(body)
    raise RequestError, 'roast response carried no output_text' unless text

    critic = JSON.parse(text)
    validate_critic!(critic)
    critic
  rescue JSON::ParserError
    raise RequestError, 'roast response was not valid JSON'
  end

  def output_text(body)
    Array(body['output']).flat_map { |item| Array(item['content']) }
                         .find { |c| c['type'] == 'output_text' }&.fetch('text', nil)
  end

  def validate_critic!(critic)
    raise RequestError, 'roast score must be 0 to 10' unless critic['score'].is_a?(Numeric) && critic['score'].between?(0, 10)
    raise RequestError, 'roast issues must be a list' unless critic['issues'].is_a?(Array)

    bad = critic['issues'].find { |i| !PRIORITIES.include?(i['priority']) }
    raise RequestError, "roast issue has an unknown priority: #{bad['priority'].inspect}" if bad
    raise RequestError, 'roast issue has no where' if critic['issues'].any? { |i| location(i).strip.empty? }
    raise RequestError, 'roast thirty_second_test verdict is invalid' unless VERDICTS.include?(critic.dig('thirty_second_test', 'verdict'))
    raise RequestError, 'roast purpose_test must be a list' unless critic['purpose_test'].is_a?(Array)

    bad_outcome = critic['purpose_test'].find { |o| !o.is_a?(Hash) || !VERDICTS.include?(o['verdict']) }
    raise RequestError, 'roast purpose_test verdict is invalid' if bad_outcome
  end

  # Returns the cached critic JSON, making the paid call only on a miss.
  def critique(brief:, shots:, history:, round:, cache_root:, texts: [], transcript: nil, review: nil, http: nil, model: MODEL, allow_sensitive: false)
    check_sensitive!(brief: brief, texts: texts, transcript: transcript, review: review, history: history, allow: allow_sensitive)
    key = request_key(brief: brief, shots: shots, history: history, round: round, texts: texts, transcript: transcript, review: review, model: model)
    path = WalkthroughCache.fetch(*cache_args(cache_root, key)) do |tmp|
      request = build_request(brief: brief, shots: shots, history: history, round: round, texts: texts, transcript: transcript, review: review, model: model)
      File.write(tmp, JSON.generate(parse_critic(post(request, http))))
    end
    JSON.parse(File.read(path))
  end

  # Refuses before any paid call when the brief, text inputs, transcript, or the
  # rendered review text, or prior-round history matches the user's sensitive-terms list. Names only the
  # count, never a term. Shared by Cli.critique and every direct caller.
  def check_sensitive!(brief:, texts: [], transcript: nil, review: nil, history: [], allow: false)
    return if allow

    bodies = [ brief, *Array(texts).map { |f| File.read(f) }, transcript, review_text(review),
               (history.empty? ? nil : JSON.generate(history)) ].compact
    hits = SensitiveTerms.matched(bodies, SensitiveTerms.load)
    return if hits.empty?

    raise SensitiveError, "roast refused: #{hits.size} sensitive term(s) matched in the brief, text inputs, transcript, review contract, or prior rounds; pass --allow-sensitive to send anyway"
  end

  # USD one round will cost: nothing when cached, else the token estimate.
  def round_usd(cache_root, **inputs)
    cached?(cache_root, **inputs) ? 0.0 : estimate(**inputs.slice(:brief, :shots, :history, :texts, :transcript, :review))[:usd]
  end

  def cached?(cache_root, **inputs)
    File.file?(WalkthroughCache.path(*cache_args(cache_root, request_key(**inputs))))
  end

  # The WalkthroughCache coordinates (root, kind, key, ext) of one cached critic.
  def cache_args(cache_root, key) = [ cache_root, :roasts, key, 'json' ]
  private_class_method :cache_args

  def render_markdown(critic, round)
    lines = [ "# Roast round #{round}", '', "Score: #{critic['score']}/10", '', critic['summary'], '' ]
    PRIORITIES.each do |p|
      critic['issues'].select { |i| i['priority'] == p }.each do |i|
        lines << "- #{p} (#{location(i)}): #{i['problem']}" << "  Fix: #{i['fix']}"
      end
    end
    t = critic['thirty_second_test']
    lines << '' << "Purpose test: #{t['verdict']}. #{t['reason']}"
    Array(critic['purpose_test']).each { |o| lines << "- #{o['verdict']}: #{o['outcome']} (#{o['reason']})" }
    lines << ''
    lines.join("\n")
  end

  def write_round(dir, round, critic)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "round-#{round}.json"), "#{JSON.pretty_generate(critic)}\n")
    File.write(File.join(dir, "round-#{round}.md"), render_markdown(critic, round))
  end

  # The stop rule over the latest logged round: target, then no P0/P1, then cap.
  def decide(history, target: DEFAULT_TARGET, cap: DEFAULT_CAP)
    return { stop: false, reason: 'no rounds yet' } if history.empty?

    last = history.last
    critic = last[:critic]
    score = critic['score']
    blockers = critic['issues'].count { |i| BLOCKING.include?(i['priority']) }
    if score >= target then { stop: true, reason: "score #{score} reached target #{target}" }
    elsif blockers.zero? then { stop: true, reason: 'no P0 or P1 issues left' }
    elsif last[:round] >= cap then { stop: true, reason: "round cap #{cap} reached" }
    else { stop: false, reason: "#{blockers} P0/P1 issue(s) open, score #{score}" }
    end
  end

  # Run returns the exit code: 0 ok, 1 a named failure, 2 usage (as image.rb), 3 kind ambiguous.
  module Cli
    module_function

    def run(argv, out: $stdout, http: nil)
      args = argv.dup
      if args.first == 'decide'
        args.shift
        return decide(parse_decide(args), out)
      end
      if args.first == 'infer'
        args.shift
        return infer(parse_infer(args), out)
      end
      if args.first == 'settings'
        args.shift
        return settings(parse_settings(args), out)
      end

      opts = parse(args)
      WalkthroughEnv.load_secrets
      critique(opts, out, http)
      0
    rescue UsageError, OptionParser::ParseError => e
      out.puts("error: #{e.message}", USAGE)
      2
    rescue RoastKind::Ambiguous => e
      out.puts(e.message)
      3
    rescue CeilingError, SensitiveError, RequestError, WalkthroughEnv::MissingKeyError, SystemCallError, DesignConfig::Error => e
      out.puts("error: #{e.message}")
      1
    end

    # The change_config.design.roast keys a repo's CHANGE.md sets explicitly,
    # validated, as option keys. Only set keys apply, so a repo with no block
    # keeps this script's own defaults; a flag given on the command line wins.
    def configured(repo)
      path = File.join(repo.to_s, 'CHANGE.md')
      front = File.exist?(path) ? ChangeFrontmatter.parse_file(path) : {}
      block = front.is_a?(Hash) ? front.dig('change_config', 'design') : nil
      roast = DesignConfig.from_hash(block).roast
      set = (block.is_a?(Hash) && block['roast'].is_a?(Hash) ? block['roast'] : {}).keys
      { auto: roast.auto, target: roast.target, cap: roast.rounds, max_usd: roast.max_usd, model: roast.model,
        kind: roast.kind, audience: roast.audience }
        .select { |k, _| set.include?(CONFIG_KEYS.fetch(k)) }.compact
    end

    CONFIG_KEYS = { auto: 'auto', target: 'target', cap: 'rounds', max_usd: 'max_usd', model: 'model', kind: 'kind', audience: 'audience' }.freeze

    def repo_arg(args)
      i = args.index('--repo')
      return Dir.pwd unless i

      args.delete_at(i)
      args.delete_at(i) || raise(UsageError, '--repo needs a directory')
    end

    def parse(args)
      repo = repo_arg(args)
      opts = { shots: [], texts: [], max_usd: DEFAULT_CEILING_USD, cache: '.cache', out_dir: DEFAULT_OUT_DIR, model: MODEL, flags: { purpose: [] } }
             .merge(configured(repo).slice(:max_usd, :model).merge(config_review: configured(repo).slice(:kind, :audience)))
      OptionParser.new do |o|
        o.on('--model NAME') { |v| opts[:model] = v }
        o.on('--brief FILE') { |v| opts[:brief_file] = v }
        o.on('--shot IMG') { |v| opts[:shots] << v }
        o.on('--text FILE') { |v| opts[:texts] << v }
        o.on('--allow-sensitive') { opts[:allow_sensitive] = true }
        o.on('--history DIR') { |v| opts[:history] = v }
        o.on('--out-dir DIR') { |v| opts[:out_dir] = v }
        o.on('--round N', Integer) { |v| opts[:round] = v }
        o.on('--max-usd N', Float) { |v| opts[:max_usd] = v }
        o.on('--cache DIR') { |v| opts[:cache] = v }
        o.on('--transcript FILE') { |v| opts[:transcript_file] = v }
        o.on('--estimate-only') { opts[:estimate_only] = true }
        o.on('--storyboard FILE') { |v| opts[:storyboard_file] = v }
        o.on('--kind KIND') { |v| opts[:flags][:kind] = v }
        o.on('--audience TEXT') { |v| opts[:flags][:audience] = v }
        o.on('--purpose OUTCOME') { |v| opts[:flags][:purpose] << v }
      end.parse!(args)
      opts[:shots] += args
      raise UsageError, '--brief is required' unless opts[:brief_file]
      raise UsageError, 'give at least one --shot or --text' if opts[:shots].empty? && opts[:texts].empty?

      opts
    end

    def parse_infer(args)
      opts = { texts: [] }
      OptionParser.new do |o|
        o.on('--storyboard FILE') { |v| opts[:storyboard_file] = v }
        o.on('--text FILE') { |v| opts[:texts] << v }
      end.parse!(args)
      raise UsageError, 'give --storyboard or --text' unless opts[:storyboard_file] || opts[:texts].any?

      opts
    end

    # Prints the inferred kind and confidence (exit 0), or raises Ambiguous (exit 3).
    def infer(opts, out)
      [ opts[:storyboard_file], *opts[:texts] ].compact.each { |f| raise Errno::ENOENT, f unless File.file?(f) }
      found = RoastKind.infer(storyboard: board_for(opts), texts: opts[:texts].map { |t| [ t, File.read(t) ] })
      out.puts("roast kind: #{found.kind} (confidence #{found.confidence}): #{found.reason}")
      0
    end

    def parse_decide(args)
      repo = repo_arg(args)
      opts = { out_dir: DEFAULT_OUT_DIR, target: DEFAULT_TARGET, cap: DEFAULT_CAP }.merge(configured(repo).slice(:target, :cap))
      OptionParser.new do |o|
        o.on('--out-dir DIR') { |v| opts[:out_dir] = v }
        o.on('--target N', Float) { |v| opts[:target] = v }
        o.on('--cap N', Integer) { |v| opts[:cap] = v }
      end.parse!(args)
      opts
    end

    def parse_settings(args)
      repo = repo_arg(args)
      raise UsageError, "unknown argument: #{args.first}" unless args.empty?

      { auto: true, target: DEFAULT_TARGET, cap: DEFAULT_CAP, max_usd: DEFAULT_CEILING_USD, model: MODEL }.merge(configured(repo))
    end

    # Prints the resolved settings; auto: false tells a loading skill (cf:design,
    # cf:prototype, cf:walkthrough) to skip the roast, as --no-roast does.
    def settings(opts, out)
      out.puts("roast settings: auto #{opts[:auto]}, target #{opts[:target]}, rounds #{opts[:cap]}, " \
               "max_usd #{format('%.2f', opts[:max_usd])}, model #{opts[:model]}")
      0
    end

    def decide(opts, out)
      d = Roast.decide(Roast.load_history(opts[:out_dir]), target: opts[:target], cap: opts[:cap])
      out.puts("roast decision: #{d[:stop] ? 'stop' : 'continue'}: #{d[:reason]}")
      0
    end

    def critique(opts, out, http)
      [ opts[:brief_file], opts[:transcript_file], opts[:storyboard_file], *opts[:shots], *opts[:texts] ].compact.each { |f| raise Errno::ENOENT, f unless File.file?(f) }
      opts[:shots].each { |s| Roast.mime_for(s) }
      inputs = inputs_for(opts, out)
      Roast.check_sensitive!(**inputs.slice(:brief, :texts, :transcript, :review, :history), allow: opts[:allow_sensitive])
      usd = announce(inputs, opts, out)
      raise CeilingError, "$#{format('%.2f', usd)} would pass the $#{format('%.2f', opts[:max_usd])} ceiling" if usd > opts[:max_usd] + 1e-9
      return if opts[:estimate_only]

      critic = Roast.critique(**inputs, cache_root: opts[:cache], http: http, allow_sensitive: opts[:allow_sensitive])
      Roast.write_round(opts[:out_dir], inputs[:round], critic)
      out.puts("roast: #{File.join(opts[:out_dir], "round-#{inputs[:round]}.json")} score #{critic['score']}/10")
    end

    def inputs_for(opts, out)
      { brief: File.read(opts[:brief_file]).strip, shots: opts[:shots], texts: opts[:texts],
        history: Roast.load_history(opts[:history] || opts[:out_dir]),
        round: opts[:round] || Roast.next_round(opts[:out_dir]),
        transcript: opts[:transcript_file] && File.read(opts[:transcript_file]).strip, review: review_for(opts, out),
        model: opts[:model] }
    end

    # The review contract; when no source names a kind, infers one from the
    # inputs and reports it, or raises RoastKind::Ambiguous (exit 3).
    def review_for(opts, out)
      board = board_for(opts) || {}
      review = Roast.resolve_review(flags: opts[:flags], storyboard: board['review'], config: opts[:config_review])
      return review if review[:kind]

      found = RoastKind.infer(storyboard: board.empty? ? nil : board, texts: opts[:texts].map { |t| [ t, File.read(t) ] })
      return review unless found

      out.puts("roast kind: #{found.kind} (inferred, confidence #{found.confidence}): #{found.reason}")
      review.merge(kind: found.kind)
    end

    def board_for(opts)
      opts[:storyboard_file] ? JSON.parse(File.read(opts[:storyboard_file])) : nil
    rescue JSON::ParserError
      raise UsageError, "#{opts[:storyboard_file]} is not valid JSON"
    end

    # Prints the estimate before any paid call and returns the USD it will cost.
    def announce(inputs, opts, out)
      usd = Roast.round_usd(opts[:cache], **inputs)
      call = usd.zero? ? '1 call (cached)' : estimate_line(inputs, Roast.estimate(**inputs.slice(:brief, :shots, :history, :texts, :transcript, :review)))
      out.puts("roast estimate: #{call}, $#{format('%.2f', usd)} to spend")
      usd
    end

    def estimate_line(inputs, est)
      "1 call, #{inputs[:shots].size} image(s), #{inputs[:texts].size} text(s), about #{est[:tokens]} tokens in, up to #{MAX_OUTPUT_TOKENS} out, about $#{format('%.2f', est[:usd])}"
    end
  end
end

exit(Roast::Cli.run(ARGV)) if __FILE__ == $PROGRAM_NAME
