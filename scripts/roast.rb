# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'net/http'
require 'optparse'
require 'uri'
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
  USAGE = 'usage: roast.rb --brief FILE --shot IMG... [--history DIR] [--out-dir DIR] [--round N] ' \
          '[--max-usd N] [--cache DIR] [--estimate-only] | roast.rb decide --out-dir DIR [--target N] [--cap N]'

  SYSTEM_PROMPT = <<~TEXT
    You are a harsh, specific UX critic. Roast the screens: no praise padding, no vague taste talk.
    Every issue names the screen, the concrete problem a user would hit, and a concrete fix the
    author can apply. Prioritize: P0 blocks the primary task, P1 badly hurts clarity or trust,
    P2 is polish. Score 0 to 10 (9 means ship it). Run the 30-second test: could a first-time
    visitor say what this is, who it is for, and what to do next within 30 seconds?
    You are given earlier rounds. Do not repeat an issue that was fixed; hold the line on one the
    author rebutted weakly; accept a rebuttal that is sound and say so in the summary.
  TEXT

  SCHEMA = {
    type: 'object', additionalProperties: false,
    required: %w[score summary issues thirty_second_test],
    properties: {
      score: { type: 'number' },
      summary: { type: 'string' },
      issues: {
        type: 'array',
        items: {
          type: 'object', additionalProperties: false, required: %w[priority screen problem fix],
          properties: {
            priority: { type: 'string', enum: PRIORITIES },
            screen: { type: 'string' }, problem: { type: 'string' }, fix: { type: 'string' }
          }
        }
      },
      thirty_second_test: {
        type: 'object', additionalProperties: false, required: %w[verdict reason],
        properties: { verdict: { type: 'string', enum: VERDICTS }, reason: { type: 'string' } }
      }
    }
  }.freeze

  class UsageError < StandardError; end
  class CeilingError < StandardError; end
  class RequestError < StandardError; end

  module_function

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

  def next_round(dir)
    (load_history(dir).map { |h| h[:round] }.max || 0) + 1
  end

  def request_key(brief:, shots:, history:, round:)
    WalkthroughCache.key(model: MODEL, brief: brief, round: round, history: history,
                         shots: shots.map { |s| Digest::SHA256.file(s).hexdigest })
  end

  def estimate(brief:, shots:, history:)
    chars = SYSTEM_PROMPT.size + brief.size + JSON.generate(history).size
    input = (chars / 4) + (shots.size * IMAGE_TOKENS)
    usd = ((input * PRICE_PER_MTOK[:input]) + (MAX_OUTPUT_TOKENS * PRICE_PER_MTOK[:output])) / 1_000_000.0
    { usd: usd.round(2), tokens: input }
  end

  def user_text(brief, history, round, shots)
    past = history.map do |h|
      "Round #{h[:round]} critic:\n#{JSON.pretty_generate(h[:critic])}\n" \
        "Round #{h[:round]} author response:\n#{h[:response] ? JSON.pretty_generate(h[:response]) : '(none recorded)'}"
    end
    [ "Round #{round}.", "Brief:\n#{brief}", "Screens, in order: #{shots.map { |s| File.basename(s) }.join(', ')}",
     (past.empty? ? 'No earlier rounds.' : "Earlier rounds:\n#{past.join("\n\n")}") ].join("\n\n")
  end

  # The pure request description: the URL and the JSON body, no auth or cache key.
  def build_request(brief:, shots:, history:, round:, model: MODEL)
    images = shots.map do |s|
      { type: 'input_image', image_url: "data:#{mime_for(s)};base64,#{Base64.strict_encode64(File.binread(s))}" }
    end
    text = { type: 'input_text', text: user_text(brief, history, round, shots) }
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
    response = (http || default_http(uri)).request(req)
    raise RequestError, "roast request failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
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
    return if VERDICTS.include?(critic.dig('thirty_second_test', 'verdict'))

    raise RequestError, 'roast thirty_second_test verdict is invalid'
  end

  # Returns the cached critic JSON, making the paid call only on a miss.
  def critique(brief:, shots:, history:, round:, cache_root:, http: nil)
    key = request_key(brief: brief, shots: shots, history: history, round: round)
    path = WalkthroughCache.fetch(*cache_args(cache_root, key)) do |tmp|
      request = build_request(brief: brief, shots: shots, history: history, round: round)
      File.write(tmp, JSON.generate(parse_critic(post(request, http))))
    end
    JSON.parse(File.read(path))
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
        lines << "- #{p} (#{i['screen']}): #{i['problem']}" << "  Fix: #{i['fix']}"
      end
    end
    t = critic['thirty_second_test']
    lines << '' << "30-second test: #{t['verdict']}. #{t['reason']}" << ''
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

  # Run returns the exit code: 0 ok, 1 a named failure, 2 usage (as image.rb).
  module Cli
    module_function

    def run(argv, out: $stdout, http: nil)
      args = argv.dup
      if args.first == 'decide'
        args.shift
        return decide(parse_decide(args), out)
      end

      opts = parse(args)
      WalkthroughEnv.load_secrets
      critique(opts, out, http)
      0
    rescue UsageError, OptionParser::ParseError => e
      out.puts("error: #{e.message}", USAGE)
      2
    rescue CeilingError, RequestError, WalkthroughEnv::MissingKeyError, SystemCallError => e
      out.puts("error: #{e.message}")
      1
    end

    def parse(args)
      opts = { shots: [], max_usd: DEFAULT_CEILING_USD, cache: '.cache', out_dir: DEFAULT_OUT_DIR }
      OptionParser.new do |o|
        o.on('--brief FILE') { |v| opts[:brief_file] = v }
        o.on('--shot IMG') { |v| opts[:shots] << v }
        o.on('--history DIR') { |v| opts[:history] = v }
        o.on('--out-dir DIR') { |v| opts[:out_dir] = v }
        o.on('--round N', Integer) { |v| opts[:round] = v }
        o.on('--max-usd N', Float) { |v| opts[:max_usd] = v }
        o.on('--cache DIR') { |v| opts[:cache] = v }
        o.on('--estimate-only') { opts[:estimate_only] = true }
      end.parse!(args)
      opts[:shots] += args
      raise UsageError, '--brief is required' unless opts[:brief_file]
      raise UsageError, 'give at least one --shot' if opts[:shots].empty?

      opts
    end

    def parse_decide(args)
      opts = { out_dir: DEFAULT_OUT_DIR, target: DEFAULT_TARGET, cap: DEFAULT_CAP }
      OptionParser.new do |o|
        o.on('--out-dir DIR') { |v| opts[:out_dir] = v }
        o.on('--target N', Float) { |v| opts[:target] = v }
        o.on('--cap N', Integer) { |v| opts[:cap] = v }
      end.parse!(args)
      opts
    end

    def decide(opts, out)
      d = Roast.decide(Roast.load_history(opts[:out_dir]), target: opts[:target], cap: opts[:cap])
      out.puts("roast decision: #{d[:stop] ? 'stop' : 'continue'}: #{d[:reason]}")
      0
    end

    def critique(opts, out, http)
      [ opts[:brief_file], *opts[:shots] ].each { |f| raise Errno::ENOENT, f unless File.file?(f) }
      opts[:shots].each { |s| Roast.mime_for(s) }
      inputs = inputs_for(opts)
      usd = announce(inputs, opts, out)
      raise CeilingError, "$#{format('%.2f', usd)} would pass the $#{format('%.2f', opts[:max_usd])} ceiling" if usd > opts[:max_usd] + 1e-9
      return if opts[:estimate_only]

      critic = Roast.critique(**inputs, cache_root: opts[:cache], http: http)
      Roast.write_round(opts[:out_dir], inputs[:round], critic)
      out.puts("roast: #{File.join(opts[:out_dir], "round-#{inputs[:round]}.json")} score #{critic['score']}/10")
    end

    def inputs_for(opts)
      { brief: File.read(opts[:brief_file]).strip, shots: opts[:shots],
        history: Roast.load_history(opts[:history] || opts[:out_dir]),
        round: opts[:round] || Roast.next_round(opts[:out_dir]) }
    end

    # Prints the estimate before any paid call and returns the USD it will cost.
    def announce(inputs, opts, out)
      cached = Roast.cached?(opts[:cache], **inputs)
      est = Roast.estimate(**inputs.slice(:brief, :shots, :history))
      usd = cached ? 0.0 : est[:usd]
      call = cached ? '1 call (cached)' : estimate_line(inputs[:shots].size, est)
      out.puts("roast estimate: #{call}, $#{format('%.2f', usd)} to spend")
      usd
    end

    def estimate_line(image_count, est)
      "1 call, #{image_count} image(s), about #{est[:tokens]} tokens in, up to #{MAX_OUTPUT_TOKENS} out, about $#{format('%.2f', est[:usd])}"
    end
  end
end

exit(Roast::Cli.run(ARGV)) if __FILE__ == $PROGRAM_NAME
