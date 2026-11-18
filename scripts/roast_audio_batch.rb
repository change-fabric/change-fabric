# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'roast_audio_ledger'
require_relative 'roast_audio_words'

# The batch index of cf:roast --audio: DIR/batch.json is the only source of
# batch membership. Each clip has an immutable source id (from the expanded
# source path) and a current take, which starts as the source and later points
# at an approved re-voice; the source file itself is never modified. Re-running
# the same selection resumes the index; stage records carry the hashes they
# were computed from and move to stale/ the moment any of them changes.
module RoastAudioBatch
  INDEX = 'batch.json'
  DEFAULT_MAX_ATTEMPTS = 4
  TAKE_NAME = /\Asrc-\h{8}\.[at]\d+\.mp3\z/

  class UsageError < StandardError; end

  module_function

  def source_id(path) = "src-#{Digest::SHA256.hexdigest(File.expand_path(path))[0, 8]}"

  def sha(path) = path && File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil

  def sibling(audio, ext) = File.join(File.dirname(audio), "#{File.basename(audio, '.*')}#{ext}")

  # A gate output or a re-voiced take named where a source belongs.
  def take_path?(path) = File.basename(path).match?(TAKE_NAME) || File.expand_path(path).match?(%r{/src-\h{8}/(takes|fixed)/})

  # [{ source_audio:, vtt:, alignment: }] in --audio order. --vtt and
  # --alignment pair by position, else by sibling <stem>.vtt and
  # <stem>.alignment.json. A count mismatch, a missing VTT, or a flag that
  # disagrees with an existing sibling is a usage error.
  def pair(audios, vtts: [], alignments: [])
    audios.each { |a| raise UsageError, "#{a} is a roast take; name its source clip instead" if take_path?(a) }
    raise UsageError, "#{vtts.size} --vtt for #{audios.size} --audio; give one per clip or none" unless vtts.empty? || vtts.size == audios.size
    raise UsageError, "#{alignments.size} --alignment for #{audios.size} --audio; give one per clip or none" unless alignments.empty? || alignments.size == audios.size

    audios.each_with_index.map do |audio, i|
      { source_audio: audio, vtt: pick(audio, vtts[i], '.vtt', required: true), alignment: pick(audio, alignments[i], '.alignment.json') }
    end
  end

  def pick(audio, flag, ext, required: false)
    near = sibling(audio, ext)
    near = nil unless File.file?(near)
    raise UsageError, "#{flag} disagrees with the sibling #{near} for #{audio}" if flag && near && sha(flag) != sha(near)
    raise UsageError, "no captions for #{audio}: give --vtt or put #{File.basename(near || sibling(audio, ext))} beside it" if required && !(flag || near)

    flag || near
  end

  def index_path(dir) = File.join(dir, INDEX)

  def load(dir)
    path = index_path(dir)
    File.file?(path) ? JSON.parse(File.read(path)) : nil
  end

  def write(dir, batch)
    FileUtils.mkdir_p(dir)
    path = index_path(dir)
    File.write("#{path}.tmp", "#{JSON.pretty_generate(batch)}\n")
    File.rename("#{path}.tmp", path)
    batch
  end

  # Opens or resumes DIR/batch.json for this selection. pairs is pair's
  # result. A selection that adds or drops a source is a usage error unless
  # new_batch. Resume keeps each clip's current take and attempts and refreshes
  # the caption and alignment binding from this run's pairing.
  # settings: what freshness is judged against later, so summary and decide
  # can revalidate with no flags: gate_config_hash, fix, model, rubric_version,
  # target, run_max_usd, word_response.
  def open(dir, pairs, config_hash:, brief: nil, manifest: nil, max_attempts: nil, new_batch: false, settings: {})
    ids = check_ids!(pairs)
    old = load(dir)
    if old && !new_batch
      had = old['clips'].map { |c| c['source_id'] }.sort
      raise UsageError, "this selection differs from #{index_path(dir)} (#{diff_line(had, ids.keys.sort)}); pass --new-batch to start over" unless had == ids.keys.sort
    end
    previous = (new_batch ? nil : old)&.fetch('clips')&.to_h { |c| [ c['source_id'], c ] } || {}
    clips = pairs.map { |p| clip(p, previous[source_id(p[:source_audio])], max_attempts) }
    write(dir, { 'config_hash' => config_hash, 'settings' => settings, 'brief' => file_ref(brief), 'manifest' => file_ref(manifest), 'clips' => clips })
  end

  def check_ids!(pairs)
    pairs.each_with_object({}) do |p, seen|
      id = source_id(p[:source_audio])
      path = File.expand_path(p[:source_audio])
      raise UsageError, "#{p[:source_audio]} is named twice" if seen[id] == path
      raise UsageError, "source id #{id} collides for #{seen[id]} and #{path}" if seen[id]

      seen[id] = path
    end
  end

  def diff_line(had, now)
    [ (now - had).empty? ? nil : "adds #{(now - had).join(', ')}", (had - now).empty? ? nil : "drops #{(had - now).join(', ')}" ].compact.join('; ')
  end

  def file_ref(path) = path ? { 'path' => path, 'sha256' => sha(path) } : nil

  def clip(pair, old, max_attempts)
    source = pair[:source_audio]
    source_sha = sha(source)
    current = if old && old['takes'].to_i.positive? then old['current']
    else { 'audio' => source, 'audio_sha256' => source_sha, 'alignment' => pair[:alignment], 'alignment_sha256' => sha(pair[:alignment]) }
    end
    { 'source_id' => source_id(source), 'source_audio' => source, 'source_sha256' => source_sha, 'current' => current,
      'vtt' => pair[:vtt], 'vtt_sha256' => sha(pair[:vtt]), 'takes' => old ? old['takes'].to_i : 0,
      'attempts' => old ? old['attempts'].to_i : 0,
      'max_attempts' => [ max_attempts, old && old['max_attempts'] ].compact.max || DEFAULT_MAX_ATTEMPTS,
      'state' => old ? old['state'] : 'retryable' }
  end

  def clip_dir(dir, id) = File.join(dir, id)

  # Counts an attempt before the clip is processed, and persists it.
  def bump_attempt!(dir, batch, id)
    c = batch['clips'].find { |x| x['source_id'] == id }
    c['attempts'] += 1
    write(dir, batch)
    c['attempts']
  end

  def set_state!(dir, batch, id, state)
    batch['clips'].find { |x| x['source_id'] == id }['state'] = state
    write(dir, batch)
  end

  # The record at DIR/<id>/<name> when its deps equal `deps`; a record whose
  # deps differ is moved to DIR/<id>/stale/<n>/ and nil is returned.
  def fresh(dir, id, name, deps)
    path = File.join(clip_dir(dir, id), name)
    return nil unless File.file?(path)

    record = JSON.parse(File.read(path))
    return record if record['deps'] == deps

    stale!(dir, id, name)
    nil
  rescue JSON::ParserError
    stale!(dir, id, name)
    nil
  end

  def stale!(dir, id, name)
    root = File.join(clip_dir(dir, id), 'stale')
    n = (Dir.glob(File.join(root, '*')).map { |d| File.basename(d).to_i }.max || 0) + 1
    FileUtils.mkdir_p(File.join(root, n.to_s))
    FileUtils.mv(File.join(clip_dir(dir, id), name), File.join(root, n.to_s, name))
  end

  def write_record(dir, id, name, record)
    path = File.join(clip_dir(dir, id), name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write("#{path}.tmp", "#{JSON.pretty_generate(record)}\n")
    File.rename("#{path}.tmp", path)
    path
  end

  # ---- snapshot, states, summary, decide ----------------------------------

  STATES = %w[ready retryable blocked exhausted].freeze

  # The gate deps a clip's current inputs imply, hashed from disk now.
  def gate_deps(batch, clip)
    cur = clip['current']
    st = batch['settings'] || {}
    { 'audio_sha256' => sha(cur['audio']), 'vtt_sha256' => sha(clip['vtt']), 'config_hash' => st['gate_config_hash'], 'fix' => st.fetch('fix', true),
      'alignment_sha256' => sha(cur['alignment']) }
  end

  def response_path(dir, batch, id) = (batch['settings'] || {})['word_response'] || File.join(clip_dir(dir, id), 'words.response.json')

  def judge_deps(batch, words_deps)
    st = batch['settings'] || {}
    words_deps.merge('brief_sha256' => sha(batch.dig('brief', 'path')), 'model' => st['model'], 'rubric_version' => st['rubric_version'])
  end

  def rounds(dir, id) = Dir.glob(File.join(clip_dir(dir, id), 'round-*.json')).filter_map { |p| p[/round-(\d+)\.json\z/, 1]&.to_i }.sort

  # One clip's records, revalidated against its current inputs first: any
  # record whose deps differ, or whose approved outputs changed, moves to
  # stale/ before anything reads it. Returns { gate:, words:, judge: } of fresh
  # records (nil when missing or stale).
  def revalidate(dir, batch, clip)
    id = clip['source_id']
    gate = fresh(dir, id, 'gate.json', gate_deps(batch, clip))
    if gate && !outputs_intact?(gate)
      stale!(dir, id, 'gate.json')
      gate = nil
    end
    words = gate && words_fresh(dir, batch, clip, gate)
    judge = words && judge_fresh(dir, batch, id, words)
    { gate: gate, words: words, judge: judge }
  end

  def outputs_intact?(record)
    o = record['output'] or return true
    [ %w[audio audio_sha256], %w[vtt vtt_sha256] ].all? { |f, h| sha(o[f]) == o[h] }
  end

  def words_fresh(dir, batch, clip, gate)
    id = clip['source_id']
    path = File.join(clip_dir(dir, id), 'words.json')
    return nil unless File.file?(path)

    words = JSON.parse(File.read(path))
    inputs = { 'audio_sha256' => gate['deps']['audio_sha256'], 'vtt_sha256' => gate['deps']['vtt_sha256'] }
    valid, = RoastAudioWords.rebuttals(response_path(dir, batch, id), ops: words['ops'], source: words['source'], source_id: id, inputs: inputs,
                                                                      brief: brief_text(batch), pronunciations: {})
    fresh(dir, id, 'words.json', gate['deps'].merge('rebuttal_sha256' => RoastAudioWords.sha256(valid)))
  end

  def brief_text(batch)
    path = batch.dig('brief', 'path')
    path && File.file?(path) ? File.read(path) : ''
  end

  # The latest round whose deps match; older or mismatched rounds go to stale/.
  def judge_fresh(dir, batch, id, words)
    want = judge_deps(batch, words['deps'])
    found = nil
    rounds(dir, id).reverse_each do |n|
      name = "round-#{n}.json"
      record = JSON.parse(File.read(File.join(clip_dir(dir, id), name)))
      if found.nil? && record['deps'] == want then found = record
      elsif record['deps'] != want
        stale!(dir, id, name)
        md = File.join(clip_dir(dir, id), "round-#{n}.md")
        FileUtils.rm_f(md)
      end
    end
    found
  end

  def blocking(judge) = Array(judge && judge['issues']).count { |i| %w[P0 P1].include?(i['priority']) }

  def ready?(rec, target)
    g, w, j = rec.values_at(:gate, :words, :judge)
    g && g['status'] == 'pass' && w && w['counts']['accepted'].zero? && j && blocking(j).zero? && j['score'] >= target
  end

  # [state, reason] for a clip over its fresh records. stop_at limits which
  # stages count as done for a gate-only or words-only run.
  def state(clip, rec, target:, max_attempts: nil, stop_at: 'judge')
    cap = max_attempts || clip['max_attempts']
    return [ 'ready', "score #{rec[:judge]['score']}, no P0/P1, no word errors" ] if ready?(rec, target)

    pending = pending_stage(rec, stop_at)
    return [ 'exhausted', "#{clip['attempts']} of #{cap} attempts used" ] if clip['attempts'] >= cap
    return [ 'retryable', "#{pending} to run" ] if pending

    [ 'blocked', blocked_reason(rec, target, stop_at) ]
  end

  def pending_stage(rec, stop_at)
    return 'gate' unless rec[:gate]
    return nil if stop_at == 'gate' || rec[:gate]['status'] != 'pass'
    return 'words' unless rec[:words]
    return nil if stop_at == 'words'

    rec[:judge] ? nil : 'judge'
  end

  def blocked_reason(rec, target, stop_at)
    g, w, j = rec.values_at(:gate, :words, :judge)
    return "gate #{g['terminal'].empty? ? 'failed' : "terminal: #{g['terminal'].join(', ')}"}" if g['status'] != 'pass'
    return "#{stop_at} done; unchanged since" if stop_at != 'judge'

    parts = []
    parts << "#{w['counts']['accepted']} word error(s)" if w['counts']['accepted'].positive?
    parts << "#{blocking(j)} P0/P1" if blocking(j).positive?
    parts << "score #{j['score']} under #{target}" if j['score'] < target
    "#{parts.join(', ')}; needs a new take, a caption fix or a rebuttal"
  end

  # Every clip's fresh records and state, from one read of batch.json.
  def snapshot(dir, target:, max_attempts: nil, stop_at: 'judge')
    batch = load(dir) or raise UsageError, "no batch at #{index_path(dir)}"
    clips = batch['clips'].map do |clip|
      rec = revalidate(dir, batch, clip)
      st, reason = state(clip, rec, target: target, max_attempts: max_attempts, stop_at: stop_at)
      { clip: clip, rec: rec, state: st, reason: reason }
    end
    { batch: batch, clips: clips }
  end

  def summary_row(c)
    rec = c[:rec]
    g, w, j = rec.values_at(:gate, :words, :judge)
    { 'source_id' => c[:clip]['source_id'], 'source' => File.basename(c[:clip]['source_audio']), 'state' => c[:state], 'reason' => c[:reason],
      'attempts' => "#{c[:clip]['attempts']}/#{c[:clip]['max_attempts']}", 'gate' => g ? g['status'] : '-',
      'words' => w ? "#{w['counts']['raw']}/#{w['counts']['accepted']}" : '-', 'timing' => w ? w['timing'] : '-',
      'score' => j ? j['score'] : '-', 'p0_p1' => j ? blocking(j) : '-', 'regen' => '-' }
  end

  # summary.json and summary.md from one snapshot, and each clip's state in batch.json.
  def summary!(dir, snap)
    batch = snap[:batch]
    snap[:clips].each { |c| batch['clips'].find { |x| x['source_id'] == c[:clip]['source_id'] }['state'] = c[:state] }
    write(dir, batch)
    rows = snap[:clips].map { |c| summary_row(c) }
    write_record(dir, '.', 'summary.json', { 'clips' => rows })
    head = %w[source_id source state attempts gate words timing score p0_p1 regen reason]
    md = [ '# Audio roast summary', '', "| #{head.join(' | ')} |", "|#{' --- |' * head.size}" ]
    md += rows.map { |r| "| #{head.map { |k| r[k].to_s.gsub('|', '/') }.join(' | ')} |" }
    md << '' << 'words is raw/accepted errors; timing is verified only with bound alignment.' << ''
    File.write(File.join(dir, 'summary.md'), md.join("\n"))
    rows
  end

  # One stop decision for the batch. It continues only while some clip is
  # retryable and the run ledger can still authorize spend.
  def decide(dir, target:, max_attempts: nil)
    snap = snapshot(dir, target: target, max_attempts: max_attempts)
    summary!(dir, snap)
    by = STATES.to_h { |s| [ s, snap[:clips].select { |c| c[:state] == s } ] }
    lines = STATES.filter_map do |s|
      next if by[s].empty?

      "#{s}: #{by[s].map { |c| s == 'blocked' ? "#{c[:clip]['source_id']} (#{c[:reason]})" : c[:clip]['source_id'] }.join(', ')}"
    end
    [ lines, verdict(dir, snap[:batch], by) ]
  end

  def verdict(dir, batch, by)
    return [ true, "all #{by['ready'].size} clip(s) ready" ] if by.values_at('retryable', 'blocked', 'exhausted').all?(&:empty?)
    return [ true, 'no clip is retryable; blocked clips need a re-voice approval, a caption fix or a rebuttal' ] if by['retryable'].empty?

    cap = (batch['settings'] || {})['run_max_usd'] || 1.0
    ledger = RoastAudioLedger.new(dir, cap_usd: cap, max_usd: cap)
    data = ledger.read
    return [ true, 'the run ledger is halted' ] if data['halted']
    return [ true, "the run cap $#{format('%.2f', cap)} is reached" ] if ledger.committed(data) >= cap - 1e-9

    [ false, "#{by['retryable'].size} clip(s) retryable" ]
  rescue RoastAudioLedger::Refused => e
    [ true, "the run ledger cannot authorize spend: #{e.message}" ]
  end

  private_class_method :pick, :check_ids!, :diff_line, :file_ref, :clip, :words_fresh, :judge_fresh, :pending_stage, :blocked_reason, :verdict
end
