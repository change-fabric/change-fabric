# frozen_string_literal: true

require 'json'
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
# for prosody, pacing, emphasis and TTS artifacts. This release runs the gate
# and the word check (--stop-after gate|words); the judge is refused by name
# until it lands.
module RoastAudio
  DEFAULT_OUT_DIR = 'roast-audio'
  STAGES = %w[gate words judge].freeze
  DEFAULT_RUN_CEILING_USD = 1.0
  NOT_YET = { 'judge' => 'judge lands in phase 3 (the audio judge)' }.freeze
  USAGE = 'usage: roast.rb --audio CLIP.mp3 [--audio CLIP2.mp3]... --brief FILE [--vtt FILE]... [--alignment FILE]... ' \
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
      opts = parse(argv.dup)
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

      RoastAudioGate.validate!(opts[:gate])
      opts
    end

    # Everything a stage's freshness hangs off, plus what the run itself is held to.
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

      batch = RoastAudioBatch.open(opts[:out_dir], pairs, config_hash: batch_config_hash(opts), brief: opts[:brief], manifest: opts[:manifest],
                                                          max_attempts: opts[:max_attempts], new_batch: opts[:new_batch])
      ledger = RoastAudioLedger.new(opts[:out_dir], cap_usd: opts[:run_max_usd], max_usd: opts[:max_usd])
      results = batch['clips'].map do |c|
        gate = gate_clip(opts, batch, c, out, docker)
        words_clip(opts, c, gate, ledger, out, http) if opts[:stop_after] != 'gate' && gate['status'] == 'pass'
        gate['terminal'] == [ 'guard' ] ? 'guard' : gate['status']
      end
      out.puts("roast audio: #{results.count('pass')} of #{results.size} clip(s) pass the gate; batch #{RoastAudioBatch.index_path(opts[:out_dir])}")
      results.include?('guard') ? 1 : 0
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

    # The caption text and any manifest are what reach a provider as text, so
    # they are scanned; audio content cannot be.
    def scan!(pairs, opts)
      return if opts[:allow_sensitive]

      texts = pairs.flat_map { |p| RoastVtt.parse_file(p[:vtt]).map(&:text) }
      texts += SensitiveTerms.strings(JSON.parse(File.read(opts[:manifest]))) if opts[:manifest]
      hits = SensitiveTerms.matched(texts, SensitiveTerms.load)
      return if hits.empty?

      raise Roast::SensitiveError, "roast refused: #{hits.size} sensitive term(s) matched in the captions or manifest; pass --allow-sensitive to send anyway"
    end

    # Gates one clip's current take unless a fresh gate.json already covers it,
    # and returns the gate record.
    def gate_clip(opts, batch, clip, out, docker)
      dir = opts[:out_dir]
      id = clip['source_id']
      cur = clip['current']
      deps = RoastAudioGate.deps(audio_sha256: cur['audio_sha256'], vtt_sha256: clip['vtt_sha256'], cfg: opts[:gate], fix: !opts[:no_fix],
                                 alignment_sha256: cur['alignment_sha256'])
      record = RoastAudioBatch.fresh(dir, id, 'gate.json', deps)
      if record && !outputs_intact?(record)
        RoastAudioBatch.stale!(dir, id, 'gate.json')
        record = nil
      end
      if record
        out.puts("gate #{id} (#{File.basename(clip['source_audio'])}): #{record['status']} (unchanged, no attempt counted)")
      else
        attempt = RoastAudioBatch.bump_attempt!(dir, batch, id)
        record = RoastAudioGate.run(audio: cur['audio'], vtt: clip['vtt'], id: id, attempt: attempt, cfg: opts[:gate], docker: docker,
                                    out_dir: File.join(RoastAudioBatch.clip_dir(dir, id), 'fixed'), fix: !opts[:no_fix], words: words(cur),
                                    alignment_sha256: cur['alignment_sha256'])
        RoastAudioBatch.write_record(dir, id, 'gate.json', record)
        RoastAudioBatch.set_state!(dir, batch, id, record['terminal'].empty? ? 'retryable' : 'blocked')
        out.puts(gate_line(id, clip, record))
      end
      record
    end

    # A record is only as good as the files it approved: a missing or edited output is stale.
    def outputs_intact?(record)
      o = record['output'] or return true
      [ %w[audio audio_sha256], %w[vtt vtt_sha256] ].all? { |f, h| RoastAudioBatch.sha(o[f]) == o[h] }
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

    private_class_method :window, :check!, :process, :estimate, :words_estimate, :words_clip, :scan!, :gate_clip, :outputs_intact?, :words, :gate_line
  end
end
