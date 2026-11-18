# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'net/http'
require 'optparse'
require_relative 'roast' unless defined?(Roast::Cli) # already loaded when roast.rb is the program
require_relative 'roast_audio_batch'
require_relative 'roast_audio_gate'
require_relative 'roast_audio_ledger'
require_relative 'roast_audio_words'
require_relative 'roast_vtt'
require_relative 'sensitive_terms'

# cf:roast --audio: roasts a batch of narration clips, each with its WebVTT
# captions. Every clip goes through a free deterministic gate with auto-fix
# first, then a word check against the captions, then an OpenAI audio judge
# for prosody, pacing, emphasis and TTS artifacts. The judge hears the gated
# clip through Chat Completions (the Responses API takes no audio), cites
# caption cues, and Ruby turns each cue into its m:ss.s stamp. Every paid call
# goes through the run ledger.
module RoastAudio
  DEFAULT_OUT_DIR = 'roast-audio'
  STAGES = %w[gate words judge].freeze
  DEFAULT_RUN_CEILING_USD = 1.0
  NOT_YET = {}.freeze
  CHAT_URL = 'https://api.openai.com/v1/chat/completions'
  DEFAULT_MODEL = 'gpt-audio-1.5'
  # Bump when the rubric or the reply shape changes: it is a judge dep, so
  # every round judged under the old rubric goes stale.
  RUBRIC_VERSION = 1
  # The output cap a judge call sends and reserves (max_completion_tokens).
  JUDGE_MAX_OUTPUT_TOKENS = RoastAudioLedger::MAX_OUTPUT_TOKENS
  # How the reply's JSON is asked for: 'prompt' states the schema in the
  # system prompt and parses the first JSON object of the reply. gpt-audio-1.5
  # answered response_format json_schema with HTTP 400 "not supported with this
  # model" (probed 2026-11-18), so 'json_schema' stays only for a model that takes it.
  RESPONSE_FORMAT = 'prompt'
  AREAS = %w[prosody pacing emphasis artifact].freeze

  SYSTEM_PROMPT = <<~TEXT
    You are a harsh, specific critic of one narration clip. You hear the audio and read its caption
    cues, each with an index and a start time. Judge only what a measurement cannot:
    - prosody: intonation, stress, phrasing that sounds read rather than spoken;
    - pacing: words per minute, pauses that drag or rush, a clip that races or stalls;
    - emphasis: the words the brief needs stressed, and stress on the wrong word;
    - artifact: TTS glitches, metallic or robotic tone, clicks, odd breaths, warble, a
      mispronounced word, audible noise or hum.
    Do not judge word accuracy, loudness, levels, or file format; those are checked elsewhere.
    Every issue cites the cue index it falls in. Priorities: P0 makes a listener stop trusting or
    following the clip, P1 is clearly unnatural for the brief's audience, P2 is polish. Set revoice
    true when only a new take can fix the issue.
    Score 0 to 10 for the brief's audience. Anchors: 3 fails its audience, 5 has a blocking flaw,
    7 is usable with clear fixes left, 9 is ready to ship to a client.
    You may be given earlier rounds for this exact take; do not repeat a fixed issue.
  TEXT

  SCHEMA = {
    type: 'object', additionalProperties: false, required: %w[score summary issues],
    properties: {
      score: { type: 'number' }, summary: { type: 'string' },
      issues: { type: 'array', items: { type: 'object', additionalProperties: false, required: %w[priority cue area problem fix revoice],
                                         properties: { priority: { type: 'string', enum: Roast::PRIORITIES }, cue: { type: 'integer' },
                                                       area: { type: 'string', enum: AREAS }, problem: { type: 'string' },
                                                       fix: { type: 'string' }, revoice: { type: 'boolean' } } } }
    }
  }.freeze

  PROMPT_SHAPE = "Reply with exactly one JSON object and nothing else, matching this JSON Schema:\n#{JSON.generate(SCHEMA)}".freeze

  module_function

  def system_prompt = RESPONSE_FORMAT == 'json_schema' ? SYSTEM_PROMPT : "#{SYSTEM_PROMPT}\n#{PROMPT_SHAPE}"

  def user_text(brief:, cues:, words:, history:)
    numbered = cues.map { |c| "#{c.index}. [#{RoastVtt.mmss(c.start_ms)}] #{c.text}" }
    word_line = "Word check (#{words['source']}): #{words['counts']['accepted']} accepted word error(s); timing #{words['timing']}. " \
                'Word accuracy is handled there; do not report it.'
    past = history.map { |h| "Round #{h['round']} critic:\n#{JSON.generate(h.slice('score', 'summary', 'issues'))}" }
    [ "Brief:\n#{brief}", "Caption cues:\n#{numbered.join("\n")}", word_line,
      past.empty? ? 'No earlier rounds for this take.' : "Earlier rounds:\n#{past.join("\n\n")}",
      'The narration audio follows.' ].join("\n\n")
  end

  # A Chat Completions body with one input_audio part (gpt-audio models take
  # audio only there). Returns { url:, body:, prompt_bytes: }.
  def build_request(audio:, brief:, cues:, words:, history:, model: DEFAULT_MODEL, max_output: JUDGE_MAX_OUTPUT_TOKENS)
    text = user_text(brief: brief, cues: cues, words: words, history: history)
    body = { model: model, modalities: [ 'text' ], max_completion_tokens: max_output,
             messages: [ { role: 'system', content: system_prompt },
                         { role: 'user', content: [ { type: 'text', text: text },
                                                    { type: 'input_audio', input_audio: { data: Base64.strict_encode64(File.binread(audio)), format: 'mp3' } } ] } ] }
    schema = { type: 'json_schema', json_schema: { name: 'audio_roast', strict: true, schema: SCHEMA } }
    body[:response_format] = schema if RESPONSE_FORMAT == 'json_schema'
    bytes = system_prompt.bytesize + text.bytesize + (RESPONSE_FORMAT == 'json_schema' ? JSON.generate(schema).bytesize : 0)
    { url: CHAT_URL, body: body, prompt_bytes: bytes }
  end

  def judge_bound(request, duration_s)
    RoastAudioLedger.bound('judge', model: request[:body][:model], duration_s: duration_s, prompt_bytes: request[:prompt_bytes],
                                    max_output_tokens: request[:body][:max_completion_tokens])
  end

  # Called only from inside ledger.spend. No retry: a retry would spend
  # outside its reservation.
  def post_chat(request, http)
    uri = URI(request[:url])
    begin
      key = WalkthroughEnv.openai_key!
      req = Net::HTTP::Post.new(uri)
      req['Authorization'] = "Bearer #{key}"
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(request[:body])
    rescue StandardError
      raise RoastAudioLedger::PreDispatch, 'judge request not sent'
    end
    response = Roast.transport { (http || Roast.default_http(uri)).request(req) }
    failure = CfProviderError.from_response(provider: 'openai', response: response, key: key)
    raise failure if failure

    JSON.parse(response.body)
  end

  # The critic from a Chat Completions body: the content parsed as JSON (or
  # its first JSON object), validated, with each issue's where filled from
  # its cue. Raises Roast::RequestError by name.
  def parse_critic(body, cues:)
    msg = body.dig('choices', 0, 'message') || {}
    raise Roast::RequestError, "audio judge refused: #{msg['refusal']}" if msg['refusal']

    text = msg['content'].to_s
    critic = begin
      JSON.parse(text)
    rescue JSON::ParserError
      first_object(text) or raise Roast::RequestError, 'audio judge reply has no JSON object'
    end
    validate!(critic, cues)
    by_index = cues.to_h { |c| [ c.index, c ] }
    critic.merge('issues' => critic['issues'].map { |i| i.merge('at' => RoastVtt.mmss(by_index[i['cue']].start_ms), 'where' => "cue #{i['cue']} at #{RoastVtt.mmss(by_index[i['cue']].start_ms)}") })
  end

  def first_object(text)
    start = text.index('{') or return nil
    depth = 0
    in_string = false
    escaped = false
    text[start..].each_char.with_index do |ch, i|
      if in_string
        if escaped then escaped = false
        elsif ch == '\\' then escaped = true
        elsif ch == '"' then in_string = false
        end
      elsif ch == '"' then in_string = true
      elsif ch == '{' then depth += 1
      elsif ch == '}'
        depth -= 1
        return JSON.parse(text[start..start + i]) if depth.zero?
      end
    end
    nil
  rescue JSON::ParserError
    nil
  end

  def validate!(critic, cues)
    raise Roast::RequestError, 'audio judge reply is not an object' unless critic.is_a?(Hash)
    raise Roast::RequestError, 'audio judge score must be 0 to 10' unless critic['score'].is_a?(Numeric) && critic['score'].between?(0, 10)
    raise Roast::RequestError, 'audio judge issues must be a list' unless critic['issues'].is_a?(Array)

    critic['issues'].each_with_index do |i, n|
      problem = issue_problem(i, cues.size)
      raise Roast::RequestError, "audio judge issue #{n + 1} #{problem}" if problem
    end
  end

  def issue_problem(issue, cue_count)
    return 'is not an object' unless issue.is_a?(Hash)
    return "has an unknown priority #{issue['priority'].inspect}" unless Roast::PRIORITIES.include?(issue['priority'])
    return "cites no valid cue (#{issue['cue'].inspect} of 1..#{cue_count})" unless issue['cue'].is_a?(Integer) && issue['cue'].between?(1, cue_count)
    return "has an unknown area #{issue['area'].inspect}" unless AREAS.include?(issue['area'])
    return 'has no revoice boolean' unless [ true, false ].include?(issue['revoice'])

    'has an empty problem or fix' if issue['problem'].to_s.strip.empty? || issue['fix'].to_s.strip.empty?
  end

  def render_markdown(critic, round)
    lines = [ "# Audio roast round #{round}", '', "Score: #{critic['score']}/10", '', critic['summary'].to_s, '' ]
    Roast::PRIORITIES.each do |p|
      critic['issues'].select { |i| i['priority'] == p }.each do |i|
        lines << "- #{p} [#{i['where']}] #{i['area']}#{i['revoice'] ? ' (re-voice)' : ''}: #{i['problem']}" << "  Fix: #{i['fix']}"
      end
    end
    "#{lines.join("\n")}\n"
  end

  private_class_method :first_object, :issue_problem
  USAGE = 'usage: roast.rb decide --audio-batch DIR [--target N] [--max-attempts N] | roast.rb --audio CLIP.mp3 [--audio CLIP2.mp3]... --brief FILE [--vtt FILE]... [--alignment FILE]... ' \
          '[--manifest FILE] [--word-response FILE] [--out-dir DIR] [--stop-after gate|words|judge] [--model NAME] [--max-usd N] ' \
          '[--run-max-usd N] [--max-attempts N] [--cache DIR] [--estimate-only] [--no-fix] [--allow-sensitive] [--new-batch] ' \
          '[--lufs N] [--lufs-tol N] [--max-tp N] [--max-clipped N] [--noise-max DB] [--noise-window START-END]... ' \
          '[--pad-min S] [--pad-max S] [--sample-rate HZ] [--channels N] [--min-kbps N] [--fix-kbps N]'

  GATE_FLAGS = {
    '--lufs N' => [ :lufs, Float ], '--lufs-tol N' => [ :lufs_tol, Float ], '--max-tp N' => [ :max_tp, Float ],
    '--max-clipped N' => [ :max_clipped, Integer ], '--noise-max DB' => [ :noise_max, Float ], '--pad-min S' => [ :pad_min, Float ],
    '--pad-max S' => [ :pad_max, Float ], '--sample-rate HZ' => [ :sample_rate, Integer ], '--channels N' => [ :channels, Integer ],
    '--min-kbps N' => [ :min_kbps, Integer ], '--fix-kbps N' => [ :fix_kbps, Integer ]
  }.freeze

  module Cli
    module_function

    def run(argv, out: $stdout, docker: RoastAudioGate::DEFAULT_DOCKER, http: nil)
      args = argv.dup
      return decide(parse_decide(args.drop(1)), out) if args.first == 'decide'

      opts = parse(args)
      process(opts, out, docker, http)
    rescue RoastAudioBatch::UsageError, RoastAudioGate::UsageError, Roast::UsageError, OptionParser::ParseError => e
      out.puts("error: #{e.message}", USAGE)
      2
    rescue WalkthroughEnv::NeedsEnrollment => e
      WalkthroughEnv.enroll(e, out: out)
    rescue CfProviderError::Failure => e
      WalkthroughEnv.key_error(e, out: out)
    rescue Roast::SensitiveError, RoastAudioGate::GateError, RoastVtt::ParseError, RoastAudioLedger::Refused, RoastAudioLedger::UnboundedCost,
           RoastAudioWords::WordsError, Roast::RequestError, WalkthroughEnv::MissingKeyError, JSON::ParserError, SystemCallError => e
      out.puts("error: #{e.message}")
      1
    end

    def parse(args)
      opts = { audios: [], vtts: [], alignments: [], out_dir: DEFAULT_OUT_DIR, stop_after: 'judge', max_usd: Roast::DEFAULT_CEILING_USD,
               run_max_usd: DEFAULT_RUN_CEILING_USD, cache: '.cache', gate: RoastAudioGate::DEFAULTS.dup.merge(noise_windows: []) }
      OptionParser.new do |o|
        o.on('--audio FILE') { |v| opts[:audios] << v }
        o.on('--brief FILE') { |v| opts[:brief] = v }
        o.on('--vtt FILE') { |v| opts[:vtts] << v }
        o.on('--alignment FILE') { |v| opts[:alignments] << v }
        o.on('--manifest FILE') { |v| opts[:manifest] = v }
        o.on('--word-response FILE') { |v| opts[:word_response] = v }
        o.on('--out-dir DIR') { |v| opts[:out_dir] = v }
        o.on('--stop-after STAGE') { |v| opts[:stop_after] = v }
        o.on('--model NAME') { |v| opts[:model] = v }
        o.on('--max-usd N', Float) { |v| opts[:max_usd] = v }
        o.on('--run-max-usd N', Float) { |v| opts[:run_max_usd] = v }
        o.on('--max-attempts N', Integer) { |v| opts[:max_attempts] = v }
        o.on('--cache DIR') { |v| opts[:cache] = v }
        o.on('--estimate-only') { opts[:estimate_only] = true }
        o.on('--no-fix') { opts[:no_fix] = true }
        o.on('--allow-sensitive') { opts[:allow_sensitive] = true }
        o.on('--new-batch') { opts[:new_batch] = true }
        o.on('--noise-window START-END') { |v| opts[:gate][:noise_windows] << window(v) }
        GATE_FLAGS.each { |flag, (key, type)| o.on(flag, type) { |v| opts[:gate][key] = v } }
      end.parse!(args)
      raise RoastAudioBatch::UsageError, "unexpected argument: #{args.first}" unless args.empty?

      check!(opts)
    end

    def parse_decide(args)
      opts = { target: Roast::DEFAULT_TARGET }
      OptionParser.new do |o|
        o.on('--audio-batch DIR') { |v| opts[:dir] = v }
        o.on('--target N', Float) { |v| opts[:target] = v }
        o.on('--max-attempts N', Integer) { |v| opts[:max_attempts] = v }
      end.parse!(args)
      raise RoastAudioBatch::UsageError, 'decide needs --audio-batch DIR' unless opts[:dir]

      opts
    end

    def decide(opts, out)
      lines, (stop, reason) = RoastAudioBatch.decide(opts[:dir], target: opts[:target], max_attempts: opts[:max_attempts],
                                                                 pending_bound: ->(batch, c) { pending_bound(opts[:dir], batch, c) })
      lines.each { |l| out.puts(l) }
      out.puts("roast decision: #{stop ? 'stop' : 'continue'}: #{reason}")
      0
    end

    # The bound of the next paid call a retryable clip would make: 0 when its
    # next stage is free (the gate, bound alignment, a cached transcript).
    def pending_bound(dir, batch, c)
      gate = c[:rec][:gate]
      return 0.0 unless gate && gate['status'] == 'pass'

      id = c[:clip]['source_id']
      duration = gate.dig('measurements', 'output', 'duration_s') || gate.dig('measurements', 'source', 'duration_s')
      if c[:rec][:words].nil?
        cur = c[:clip]['current']
        free = RoastAudioWords.provenance(cur['alignment'], audio_sha256: cur['audio_sha256'])[:status] == 'verified' ||
               File.file?(RoastAudioWords.cache_path(RoastAudioBatch.clip_dir(dir, id), gate['output']['audio_sha256'], RoastAudioWords::TRANSCRIBE_MODEL))
        return free ? 0.0 : RoastAudioWords.transcribe_bound(duration)[:usd]
      end
      st = batch['settings'] || {}
      request = RoastAudio.build_request(audio: gate['output']['audio'], brief: RoastAudioBatch.brief_text(batch).strip, cues: RoastVtt.parse_file(gate['output']['vtt']),
                                         words: c[:rec][:words], history: [], model: st['model'] || DEFAULT_MODEL)
      RoastAudio.judge_bound(request, duration)[:usd]
    end

    def window(text)
      m = text.match(/\A(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)\z/) or raise RoastAudioBatch::UsageError, "--noise-window wants START-END in seconds, got #{text}"
      s, e = m[1].to_f, m[2].to_f
      raise RoastAudioBatch::UsageError, "--noise-window #{text} ends before it starts" unless e > s

      [ s, e ]
    end

    def check!(opts)
      raise RoastAudioBatch::UsageError, 'give at least one --audio' if opts[:audios].empty?
      raise RoastAudioBatch::UsageError, '--brief is required' unless opts[:brief]
      raise RoastAudioBatch::UsageError, "--stop-after must be one of #{STAGES.join(', ')}" unless STAGES.include?(opts[:stop_after])
      raise RoastAudioBatch::UsageError, "#{NOT_YET.fetch(opts[:stop_after])}; run --stop-after words for now" if NOT_YET.key?(opts[:stop_after])
      raise RoastAudioBatch::UsageError, '--max-attempts must be at least 1' if opts[:max_attempts] && opts[:max_attempts] < 1

      opts[:model] ||= DEFAULT_MODEL

      RoastAudioGate.validate!(opts[:gate])
      opts
    end

    # Everything a stage's freshness hangs off, plus what the run itself is held to.
    def settings(opts)
      { 'gate_config_hash' => RoastAudioGate.config_hash(opts[:gate]), 'fix' => !opts[:no_fix], 'model' => opts[:model], 'rubric_version' => RUBRIC_VERSION,
        'target' => Roast::DEFAULT_TARGET, 'run_max_usd' => opts[:run_max_usd], 'max_usd' => opts[:max_usd], 'word_response' => opts[:word_response] }
    end

    def batch_config_hash(opts)
      Digest::SHA256.hexdigest(JSON.generate({ gate: RoastAudioGate.config_hash(opts[:gate]), model: opts[:model], stop_after: opts[:stop_after],
                                               target: Roast::DEFAULT_TARGET, max_usd: opts[:max_usd], run_max_usd: opts[:run_max_usd] }))
    end

    def process(opts, out, docker, http)
      [ *opts[:audios], opts[:brief], *opts[:vtts], *opts[:alignments], opts[:manifest], opts[:word_response] ].compact.each do |f|
        raise Errno::ENOENT, f unless File.file?(f)
      end
      pairs = RoastAudioBatch.pair(opts[:audios], vtts: opts[:vtts], alignments: opts[:alignments])
      scan!(pairs, opts)
      return estimate(opts, pairs, out) if opts[:estimate_only]

      if opts[:stop_after] == 'judge' && !RoastAudioLedger::AUDIO_PRICES.key?(opts[:model])
        raise RoastAudioLedger::UnboundedCost, "no price for #{opts[:model]}; refusing an unbounded judge call"
      end

      dir = opts[:out_dir]
      RoastAudioBatch.open(dir, pairs, config_hash: batch_config_hash(opts), brief: opts[:brief], manifest: opts[:manifest],
                                       max_attempts: opts[:max_attempts], new_batch: opts[:new_batch], settings: settings(opts))
      ledger = RoastAudioLedger.new(dir, cap_usd: opts[:run_max_usd], max_usd: opts[:max_usd])
      snap = RoastAudioBatch.snapshot(dir, target: Roast::DEFAULT_TARGET, stop_at: opts[:stop_after])
      guard = false
      snap[:clips].each do |c|
        if c[:state] != 'retryable'
          guard ||= c[:rec][:gate]&.dig('terminal') == [ 'guard' ]
          out.puts("#{c[:clip]['source_id']} (#{File.basename(c[:clip]['source_audio'])}): skipped, #{c[:state]}: #{c[:reason]} (unchanged, no attempt counted)")
          next
        end
        guard |= process_clip(opts, snap[:batch], c, ledger, out, docker, http) == 'guard'
      end
      rows = RoastAudioBatch.summary!(dir, RoastAudioBatch.snapshot(dir, target: Roast::DEFAULT_TARGET, stop_at: opts[:stop_after]))
      counts = rows.group_by { |r| r['state'] }.transform_values(&:size)
      out.puts("roast audio: #{RoastAudioBatch::STATES.map { |st| "#{counts.fetch(st, 0)} #{st}" }.join(', ')}; summary #{File.join(dir, 'summary.md')}")
      guard ? 1 : 0
    end

    # One attempt: counted first, then gate, words and judge in order, each
    # reused while fresh. Returns the gate status, or 'guard'.
    def process_clip(opts, batch, snap_clip, ledger, out, docker, http)
      clip = snap_clip[:clip]
      clip['attempts'] = RoastAudioBatch.bump_attempt!(opts[:out_dir], batch, clip['source_id'])
      gate = gate_clip(opts, clip, snap_clip[:rec][:gate], out, docker)
      return 'guard' if gate['terminal'] == [ 'guard' ]
      return gate['status'] if opts[:stop_after] == 'gate' || gate['status'] != 'pass'

      words = words_clip(opts, clip, gate, ledger, out, http)
      judge_clip(opts, clip, gate, words, ledger, out, http) if opts[:stop_after] == 'judge'
      gate['status']
    end

    # The judge on a passing gate, unless a round with the same deps exists.
    def judge_clip(opts, clip, gate, words, ledger, out, http)
      dir = opts[:out_dir]
      id = clip['source_id']
      batch = RoastAudioBatch.load(dir)
      deps = RoastAudioBatch.judge_deps(batch, words['deps'])
      existing = RoastAudioBatch.rounds(dir, id).map { |n| JSON.parse(File.read(File.join(RoastAudioBatch.clip_dir(dir, id), "round-#{n}.json"))) }
      if (same = existing.reverse.find { |r| r['deps'] == deps })
        out.puts("judge #{id}: round #{same['round']} score #{same['score']} (unchanged, no call)")
        return same
      end

      cues = RoastVtt.parse_file(gate['output']['vtt'])
      round = (RoastAudioBatch.rounds(dir, id).max || 0) + 1
      request = RoastAudio.build_request(audio: gate['output']['audio'], brief: File.read(opts[:brief]).strip, cues: cues, words: words, history: [], model: opts[:model])
      duration = gate.dig('measurements', 'output', 'duration_s') || gate.dig('measurements', 'source', 'duration_s')
      body = ledger.spend('judge', RoastAudio.judge_bound(request, duration), clip: id, round: round) do
        reply = RoastAudio.post_chat(request, http)
        [ reply, reply['usage'] ]
      end
      critic = parse_or_log(body, cues, dir, id, round)
      record = critic.merge('round' => round, 'deps' => deps, 'model' => opts[:model], 'usage' => body['usage'])
      RoastAudioBatch.write_record(dir, id, "round-#{round}.json", record)
      File.write(File.join(RoastAudioBatch.clip_dir(dir, id), "round-#{round}.md"), RoastAudio.render_markdown(critic, round))
      blockers = RoastAudioBatch.blocking(critic)
      out.puts("judge #{id}: round #{round} score #{critic['score']}, #{blockers} P0/P1")
      record
    end

    # A reply that fails validation is logged raw and named; it was paid and settled already.
    def parse_or_log(body, cues, dir, id, round)
      RoastAudio.parse_critic(body, cues: cues)
    rescue Roast::RequestError => e
      raw = File.join(RoastAudioBatch.clip_dir(dir, id), 'raw', "round-#{round}.json")
      FileUtils.mkdir_p(File.dirname(raw))
      File.write(raw, JSON.pretty_generate(body))
      raise Roast::RequestError, "#{e.message} (raw reply in #{raw})"
    end

    # Display only: what the run would reserve, read from existing records
    # with no Docker call, no write and no paid call. It authorizes nothing.
    def estimate(opts, pairs, out)
      usd = 0.0
      pairs.each do |p|
        id = RoastAudioBatch.source_id(p[:source_audio])
        line = "#{id} (#{File.basename(p[:source_audio])}): gate $0.00"
        if opts[:stop_after] != 'gate'
          cost = words_estimate(opts, id, p)
          usd += cost.is_a?(Numeric) ? cost : 0
          line += ", words #{cost.is_a?(Numeric) ? format('$%.4f', cost) : cost}"
        end
        if opts[:stop_after] == 'judge'
          cost = judge_estimate(opts, id)
          usd += cost.is_a?(Numeric) ? cost : 0
          line += ", judge #{cost.is_a?(Numeric) ? format('$%.4f', cost) : cost}"
        end
        out.puts("roast estimate: #{line}")
      end
      out.puts("roast estimate: #{pairs.size} clip(s), up to $#{format('%.4f', usd)} to spend; nothing was run")
      0
    end

    def words_estimate(opts, id, pair)
      path = File.join(RoastAudioBatch.clip_dir(opts[:out_dir], id), 'gate.json')
      gate = File.file?(path) ? JSON.parse(File.read(path)) : nil
      return 'unknown until the clip is gated (run --stop-after gate first)' unless gate&.dig('output', 'audio_sha256')

      bound = RoastAudioWords.provenance(pair[:alignment], audio_sha256: gate['deps']['audio_sha256'])
      return 0.0 if bound[:status] == 'verified'
      return 0.0 if File.file?(RoastAudioWords.cache_path(RoastAudioBatch.clip_dir(opts[:out_dir], id), gate['output']['audio_sha256'], RoastAudioWords::TRANSCRIBE_MODEL))

      RoastAudioWords.transcribe_bound(gate.dig('measurements', 'output', 'duration_s') || gate.dig('measurements', 'source', 'duration_s'))[:usd]
    rescue RoastAudioLedger::UnboundedCost => e
      "refused (#{e.message})"
    end

    def judge_estimate(opts, id)
      path = File.join(RoastAudioBatch.clip_dir(opts[:out_dir], id), 'gate.json')
      gate = File.file?(path) ? JSON.parse(File.read(path)) : nil
      return 'unknown until the clip is gated (run --stop-after gate first)' unless gate&.dig('output', 'audio')

      cues = RoastVtt.parse_file(gate['output']['vtt'])
      words = { 'source' => 'transcribe', 'counts' => { 'accepted' => 0 }, 'timing' => 'unverified' }
      request = RoastAudio.build_request(audio: gate['output']['audio'], brief: File.read(opts[:brief]).strip, cues: cues, words: words, history: [], model: opts[:model])
      RoastAudio.judge_bound(request, gate.dig('measurements', 'output', 'duration_s') || gate.dig('measurements', 'source', 'duration_s'))[:usd]
    rescue RoastAudioLedger::UnboundedCost => e
      "refused (#{e.message})"
    end

    # The word check on a passing gate. It is recomputed every run (free when
    # the transcript is cached or the alignment is bound), and a words.json
    # whose deps or content changed moves to stale/.
    def words_clip(opts, clip, gate, ledger, out, http)
      dir = opts[:out_dir]
      id = clip['source_id']
      cur = clip['current']
      alignment = RoastAudioWords.provenance(cur['alignment'], audio_sha256: cur['audio_sha256'])
      response = opts[:word_response] || File.join(RoastAudioBatch.clip_dir(dir, id), 'words.response.json')
      record = RoastAudioWords.check(gate: gate, alignment: alignment, clip_dir: RoastAudioBatch.clip_dir(dir, id), id: id, ledger: ledger,
                                     response_file: response, brief: File.read(opts[:brief]), http: http)
      old = RoastAudioBatch.fresh(dir, id, 'words.json', record['deps'])
      RoastAudioBatch.stale!(dir, id, 'words.json') if old && old != record
      RoastAudioBatch.write_record(dir, id, 'words.json', record) unless old == record
      record['warnings'].each { |w| out.puts("words #{id}: #{w}") }
      c = record['counts']
      out.puts("words #{id} (#{File.basename(clip['source_audio'])}): #{c['raw']} raw, #{c['accepted']} accepted; source #{record['source']}, timing #{record['timing']}")
      record
    end

    # The brief, the caption text and any manifest are what reach a provider
    # as text, so they are scanned; audio content cannot be.
    def scan!(pairs, opts)
      return if opts[:allow_sensitive]

      texts = pairs.flat_map { |p| RoastVtt.parse_file(p[:vtt]).map(&:text) } + [ File.read(opts[:brief]) ]
      texts += SensitiveTerms.strings(JSON.parse(File.read(opts[:manifest]))) if opts[:manifest]
      hits = SensitiveTerms.matched(texts, SensitiveTerms.load)
      return if hits.empty?

      raise Roast::SensitiveError, "roast refused: #{hits.size} sensitive term(s) matched in the brief, captions or manifest; pass --allow-sensitive to send anyway"
    end

    # The fresh gate record from the snapshot, else a new gate run on the
    # clip's current take.
    def gate_clip(opts, clip, fresh, out, docker)
      return fresh.tap { |r| out.puts("gate #{clip['source_id']} (#{File.basename(clip['source_audio'])}): #{r['status']} (unchanged)") } if fresh

      dir = opts[:out_dir]
      id = clip['source_id']
      cur = clip['current']
      record = RoastAudioGate.run(audio: cur['audio'], vtt: clip['vtt'], id: id, attempt: clip['attempts'], cfg: opts[:gate], docker: docker,
                                  out_dir: File.join(RoastAudioBatch.clip_dir(dir, id), 'fixed'), fix: !opts[:no_fix], words: words(cur),
                                  alignment_sha256: cur['alignment_sha256'])
      RoastAudioBatch.write_record(dir, id, 'gate.json', record)
      out.puts(gate_line(id, clip, record))
      record
    end

    # Verified alignment word spans for the noise regions, else nil.
    def words(current)
      bound = RoastAudioWords.provenance(current['alignment'], audio_sha256: current['audio_sha256'])
      bound[:status] == 'verified' ? RoastAudioWords.spans(bound[:alignment]) : nil
    end

    def gate_line(id, clip, record)
      fixed = record['checks'].select { |_, c| c['repaired'] }.keys
      bad = record['checks'].reject { |_, c| %w[pass unverified].include?(c['status']) }.map { |k, c| "#{k} #{c['status']}" }
      unverified = record['checks'].select { |_, c| c['status'] == 'unverified' }.keys
      parts = [ "gate #{id} (#{File.basename(clip['source_audio'])}): #{record['status']}" ]
      parts << "fixed #{fixed.join(', ')} -> #{record.dig('output', 'audio')}" unless fixed.empty?
      parts << "failing #{bad.join(', ')}" unless bad.empty?
      parts << "unverified #{unverified.join(', ')}" unless unverified.empty?
      parts.join('; ')
    end

    private_class_method :window, :check!, :process, :process_clip, :judge_clip, :parse_or_log, :estimate, :words_estimate, :judge_estimate, :words_clip, :scan!, :gate_clip, :words, :gate_line, :parse_decide, :pending_bound, :settings
  end
end
