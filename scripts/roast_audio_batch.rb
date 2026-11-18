# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'roast_audio_ledger'
require_relative 'roast_audio_words'
require_relative 'elevenlabs'
require_relative 'walkthrough_env'
require_relative 'sensitive_terms'

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
                                                                      brief: brief_text(batch), pronunciations: pronunciations_for(batch, clip))
    fresh(dir, id, 'words.json', gate['deps'].merge('rebuttal_sha256' => RoastAudioWords.sha256(valid)))
  end

  def pronunciations_for(batch, clip)
    Array((manifest_for(batch)[File.basename(clip['source_audio'])] || {})['pronunciations']).to_h { |p| [ p['text'], p['say'] ] }
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
    props = proposals!(dir, snap, target: (batch['settings'] || {})['target'] || 9)
    rows = snap[:clips].map { |c| summary_row(c).merge('regen' => props.dig(c[:clip]['source_id'], 'action') || '-') }
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
  # pending_bound: ->(batch, snap_clip) { usd of the clip's next paid call }.
  def decide(dir, target:, max_attempts: nil, pending_bound: ->(_batch, _clip) { 0.0 })
    snap = snapshot(dir, target: target, max_attempts: max_attempts)
    summary!(dir, snap)
    by = STATES.to_h { |s| [ s, snap[:clips].select { |c| c[:state] == s } ] }
    lines = STATES.filter_map do |s|
      next if by[s].empty?

      "#{s}: #{by[s].map { |c| s == 'blocked' ? "#{c[:clip]['source_id']} (#{c[:reason]}#{regen_note(dir, c)})" : c[:clip]['source_id'] }.join(', ')}"
    end
    [ lines, verdict(dir, snap[:batch], by, pending_bound) ]
  end

  def regen_note(dir, c)
    path = File.join(clip_dir(dir, c[:clip]['source_id']), 'regen.json')
    return '' unless File.file?(path)

    prop = JSON.parse(File.read(path))
    "; regen #{prop['action'] == 'revoice' ? 'proposed' : prop['action']}#{prop['executable'] ? '' : ', not executable'}"
  end

  def verdict(dir, batch, by, pending_bound)
    return [ true, "all #{by['ready'].size} clip(s) ready" ] if by.values_at('retryable', 'blocked', 'exhausted').all?(&:empty?)
    return [ true, 'no clip is retryable; blocked clips need a re-voice approval, a caption fix or a rebuttal' ] if by['retryable'].empty?

    st = batch['settings'] || {}
    cap = st['run_max_usd'] || 1.0
    per_call = st['max_usd'] || cap
    ledger = RoastAudioLedger.new(dir, cap_usd: cap, max_usd: per_call)
    data = ledger.read
    return [ true, 'the run ledger is halted' ] if data['halted']

    left = cap - ledger.committed(data)
    fundable = by['retryable'].select do |c|
      usd = pending_bound.call(batch, c)
      usd <= per_call + 1e-9 && usd <= left + 1e-9
    end
    return [ true, "the $#{format('%.4f', left)} left of the run cap (per call $#{format('%.2f', per_call)}) cannot fund any retryable clip's next call" ] if fundable.empty?

    [ false, "#{fundable.size} clip(s) retryable" ]
  rescue RoastAudioLedger::Refused, RoastAudioLedger::UnboundedCost => e
    [ true, "the run ledger cannot authorize spend: #{e.message}" ]
  end

  # ---- regen proposals --------------------------------------------------------

  REVOICE_GATE = %w[clipping noise loudness true_peak].freeze
  WORD_REVOICE = %w[missing extra substituted].freeze
  DEFAULT_SETTINGS = { 'stability' => 0.5, 'similarity_boost' => 0.75, 'speed' => 1.0 }.freeze
  DEFAULT_TTS_MODEL = 'eleven_multilingual_v2'
  DEFAULT_TTS_FORMAT = 'mp3_44100_128'

  # Every reason this clip is not ready, from its fresh gate, words and judge.
  def reasons(rec, target)
    g, w, j = rec.values_at(:gate, :words, :judge)
    out = []
    Array(g && g['terminal']).each do |name|
      kind = REVOICE_GATE.include?(name) ? 'revoice' : (name == 'captions' ? 'caption' : 'report')
      out << { 'source' => 'gate', 'id' => name, 'kind' => kind, 'detail' => "gate #{name} #{g['checks'][name]['status']}: #{g['checks'][name]['measured'].to_json[0, 160]}" }
    end
    Array(w && w['ops']).reject { |o| o['rebutted'] }.each do |o|
      kind = WORD_REVOICE.include?(o['kind']) ? 'revoice' : 'caption'
      out << { 'source' => 'words', 'id' => o['id'], 'kind' => kind, 'cue' => o['cue'], 'at' => o['at'],
               'detail' => "#{o['kind']}: expected #{o['expected'].inspect}, heard #{o['heard'].inspect}" }
    end
    Array(j && j['issues']).each do |i|
      next unless %w[P0 P1].include?(i['priority'])

      out << { 'source' => 'judge', 'id' => "#{i['priority']}-#{i['area']}-#{i['cue']}", 'kind' => i['revoice'] ? 'revoice' : 'report', 'cue' => i['cue'], 'at' => i['at'],
               'area' => i['area'], 'detail' => "#{i['priority']} #{i['area']}: #{i['problem']}" }
    end
    out << { 'source' => 'judge', 'id' => 'score', 'kind' => 'report', 'detail' => "score #{j['score']} under #{target}" } if j && j['score'] < target && out.none? { |r| r['source'] == 'judge' }
    out
  end

  # Deterministic setting changes from the judge's revoice issues.
  def settings_delta(base, reasons)
    settings = base.dup
    delta = {}
    reasons.select { |r| r['source'] == 'judge' && r['kind'] == 'revoice' }.each do |r|
      if r['area'] == 'artifact' && !r['detail'].match?(/pronounc/i)
        settings['stability'] = [ settings['stability'].to_f + 0.15, 0.85 ].min.round(2)
        delta['stability'] = "+0.15 (#{r['area']} at cue #{r['cue']})"
      elsif r['area'] == 'pacing' && (step = pace_step(r['detail']))
        settings['speed'] = (settings['speed'].to_f + step).clamp(0.7, 1.2).round(2)
        delta['speed'] = "#{format('%+.2f', step)} (pacing at cue #{r['cue']})"
      end
    end
    [ settings, delta ]
  end

  def pace_step(text)
    return -0.05 if text.match?(/fast|rush|hurr|rac(e|ing)|quick/i)

    0.05 if text.match?(/slow|drag|stall|sluggish/i)
  end

  def instruction(reasons)
    parts = reasons.select { |r| r['kind'] == 'revoice' }.map { |r| [ r['cue'] && "cue #{r['cue']}", r['detail'] ].compact.join(': ') }
    hint = reasons.any? { |r| r['detail'].to_s.match?(/pronounc/i) } ? ' Add the mispronounced term to the manifest pronunciations.' : ''
    "Retake the whole clip. #{parts.join('; ')}.#{hint}"
  end

  # The regen.json proposal for one non-ready clip of a snapshot.
  def proposal(batch, snap_clip, entry, target:)
    clip = snap_clip[:clip]
    rs = reasons(snap_clip[:rec], target)
    revoice = rs.any? { |r| r['kind'] == 'revoice' }
    action = if revoice then 'revoice'
    elsif rs.any? { |r| r['kind'] == 'caption' } then 'caption-fix'
    else 'report-only'
    end
    out = { 'deps' => regen_deps(batch, snap_clip), 'source_id' => clip['source_id'], 'action' => action, 'reasons' => rs.map { |r| r.except('kind') } }
    return out.merge('executable' => false, 'why' => why_not(action)) unless action == 'revoice'

    revoice_proposal(out, clip, entry, rs)
  end

  def why_not(action) = action == 'caption-fix' ? 'fix the captions (or file a rebuttal) and re-run; no re-voice needed' : 'nothing a re-voice is known to fix'

  def revoice_proposal(out, clip, entry, rs)
    return out.merge('action' => 'report-only', 'executable' => false, 'why' => 'no manifest entry names this clip, so it cannot be re-voiced') unless entry

    pauses = Array(entry['segments']).map { |g| g['pause_ms'].to_i }
    # A re-voiced take records the settings that made it, so the next delta
    # moves on from there rather than from the manifest again.
    base = clip.dig('current', 'settings') || DEFAULT_SETTINGS.merge(entry['settings'] || {})
    settings, delta = settings_delta(base, rs)
    retake = { 'text' => entry['text'], 'segments' => entry['segments'], 'voice_id' => entry['voice_id'], 'model' => entry['model'] || DEFAULT_TTS_MODEL,
               'output_format' => entry['output_format'] || DEFAULT_TTS_FORMAT, 'settings' => settings, 'settings_delta' => delta,
               'pronunciations' => entry['pronunciations'], 'instruction' => instruction(rs) }.compact
    est = RoastAudioLedger.bound('regen', model: retake['model'], chars: retake['text'].length)[:usd]
    out = out.merge('retake' => retake, 'estimate_usd' => est)
    if pauses.any?(&:positive?)
      return out.merge('action' => 'report-only', 'executable' => false,
                       'why' => "the text is #{pauses.size} segments with pauses (pause_ms #{pauses.join(', ')}); one take cannot reproduce them faithfully, so re-voice the segments by hand")
    end
    if rs.any? { |r| r['detail'].to_s.match?(/pronounc/i) } && Array(retake['pronunciations']).empty?
      return out.merge('executable' => false, 'why' => 'a mispronunciation needs a manifest pronunciations entry first; a retake with the same text would repeat it')
    end
    return out.merge('executable' => false, 'why' => "exhausted: #{clip['attempts']} of #{clip['max_attempts']} attempts used; raise --max-attempts to allow a re-voice") if clip['attempts'] >= clip['max_attempts']

    out.merge('executable' => true)
  end

  def regen_deps(batch, snap_clip)
    rec = snap_clip[:rec]
    base = rec[:judge] ? rec[:judge]['deps'] : (rec[:words] ? rec[:words]['deps'] : rec[:gate]&.dig('deps'))
    (base || {}).merge('manifest_sha256' => (batch['settings'] || {})['manifest_sha256'], 'attempts' => snap_clip[:clip]['attempts'],
                       'max_attempts' => snap_clip[:clip]['max_attempts'])
  end

  def manifest_for(batch)
    st = batch['settings'] || {}
    manifest(st['manifest'], map: (st['manifest_map'] || {}).transform_keys(&:to_sym))
  end

  # The manifest entry for a clip, by source file name. A name shared by two
  # clips of the batch is ambiguous.
  def entry_for(batch, clip, entries)
    name = File.basename(clip['source_audio'])
    raise UsageError, "manifest entry #{name} matches #{batch['clips'].count { |c| File.basename(c['source_audio']) == name }} clips" if batch['clips'].count { |c| File.basename(c['source_audio']) == name } > 1 && entries[name]

    entries[name]
  end

  # Writes regen.json for every non-ready clip with a gate record, and drops it
  # for ready ones. Returns { source_id => proposal }.
  def proposals!(dir, snap, target:)
    entries = manifest_for(snap[:batch])
    snap[:clips].each_with_object({}) do |c, out|
      path = File.join(clip_dir(dir, c[:clip]['source_id']), 'regen.json')
      if c[:state] == 'ready' || c[:rec][:gate].nil? || c[:state] == 'retryable'
        FileUtils.rm_f(path)
        next
      end

      out[c[:clip]['source_id']] = proposal(snap[:batch], c, entry_for(snap[:batch], c[:clip], entries), target: target).tap do |prop|
        write_record(dir, c[:clip]['source_id'], 'regen.json', prop)
      end
    end
  end

  # ---- approved re-voice -----------------------------------------------------

  # Re-voices each approved clip from its current revoice proposal, through
  # the ledger, into DIR/<id>/takes/<id>.t<n>.mp3 with a bound alignment
  # sidecar, and points the clip's current take at it. Returns
  # [[id, 'ok'|refusal message], ...]; clips not approved are untouched.
  def regen!(dir, approve, transport: ElevenLabs::DEFAULT_TRANSPORT, sleeper: method(:sleep), allow_sensitive: false)
    batch = load(dir) or raise UsageError, "no batch at #{index_path(dir)}"
    st = batch['settings'] || {}
    snap = snapshot(dir, target: st['target'] || 9)
    summary!(dir, snap)
    ledger = RoastAudioLedger.new(dir, cap_usd: st['run_max_usd'] || 1.0, max_usd: st['max_usd'] || 0.5)
    approve.map do |id|
      [ id, revoice_one(dir, id, ledger, transport, sleeper, allow_sensitive) ]
    rescue RoastAudioLedger::Refused, UsageError => e
      [ id, e.message ]
    end
  end

  def revoice_one(dir, id, ledger, transport, sleeper, allow_sensitive)
    raise UsageError, "#{id} is not a clip of this batch" unless load(dir)['clips'].any? { |c| c['source_id'] == id }

    path = File.join(clip_dir(dir, id), 'regen.json')
    raise RoastAudioLedger::Refused, "#{id} has no regen proposal (it is ready or still has work to run)" unless File.file?(path)

    prop = JSON.parse(File.read(path))
    raise RoastAudioLedger::Refused, "#{id}: a #{prop['action']} proposal is not re-voiced (#{prop['why']})" unless prop['action'] == 'revoice'
    raise RoastAudioLedger::Refused, "#{id}: not executable (#{prop['why']})" unless prop['executable']

    r = prop['retake']
    hits = allow_sensitive ? [] : SensitiveTerms.matched(SensitiveTerms.strings(r.slice('text', 'segments', 'pronunciations')), SensitiveTerms.load)
    raise RoastAudioLedger::Refused, "#{id}: #{hits.size} sensitive term(s) in the retake text; pass --allow-sensitive to send anyway" unless hits.empty?

    bound = RoastAudioLedger.bound('regen', model: r['model'], chars: r['text'].length)
    guard = lambda do
      c = load(dir)['clips'].find { |x| x['source_id'] == id }
      raise RoastAudioLedger::Refused, "#{id}: #{c['attempts']} of #{c['max_attempts']} attempts used at dispatch; raise --max-attempts first" unless c['attempts'] < c['max_attempts']
    end
    decoded = ledger.spend('regen', bound, clip: id, guard: guard) { [ tts(r, transport, sleeper, File.join(dir, 'cache')), {} ] }
    store_take!(dir, id, r, decoded)
    'ok'
  end

  # The pronunciation dictionary is made before the reservation's call (it is
  # cached, and ElevenLabs bills characters of speech, not dictionaries).
  def tts(retake, transport, sleeper, cache_root)
    begin
      key = WalkthroughEnv.elevenlabs_key!
      locator = ElevenLabs.dictionary_locator(retake['pronunciations'], cache_root: cache_root, transport: transport, sleeper: sleeper) if retake['pronunciations']
      req = ElevenLabs.tts_request(text: retake['text'], voice_id: retake['voice_id'], model: retake['model'], output_format: retake['output_format'],
                                   settings: retake['settings'], locator: locator)
    rescue WalkthroughEnv::MissingKeyError, ArgumentError, KeyError
      raise RoastAudioLedger::PreDispatch, 're-voice request not sent'
    end
    ElevenLabs.decode_tts(ElevenLabs.perform(req, transport: transport, sleeper: sleeper, key: key), aliased: !locator.nil?)
  end

  def store_take!(dir, id, retake, decoded)
    batch = load(dir)
    clip = batch['clips'].find { |c| c['source_id'] == id }
    n = clip['takes'].to_i + 1
    audio = File.join(clip_dir(dir, id), 'takes', "#{id}.t#{n}.mp3")
    FileUtils.mkdir_p(File.dirname(audio))
    File.binwrite(audio, decoded[:audio])
    audio_sha = Digest::SHA256.file(audio).hexdigest
    key = ElevenLabs.audio_key(**retake.slice('text', 'voice_id', 'model', 'output_format', 'settings').transform_keys(&:to_sym))
    side = audio.sub(/\.mp3\z/, '.alignment.json')
    File.write(side, JSON.generate({ 'audio_sha256' => audio_sha, 'alignment_sha256' => RoastAudioWords.sha256(decoded[:alignment]),
                                     'generator' => { 'provider' => 'elevenlabs', 'voice_id' => retake['voice_id'], 'model' => retake['model'], 'request_key' => key },
                                     'alignment' => decoded[:alignment] }))
    clip['current'] = { 'audio' => audio, 'audio_sha256' => audio_sha, 'alignment' => side, 'alignment_sha256' => sha(side), 'settings' => retake['settings'] }
    clip['takes'] = n
    write(dir, batch)
  end

  # ---- manifest ------------------------------------------------------------

  # How to read a directory of per-clip JSON files: dotted paths, where
  # `items[]` walks each element of an array. text_path may cross one array;
  # its items are sorted by order_key and keep their own pause (pause_key).
  DEFAULT_MAP = { text_path: 'text', order_key: nil, pause_key: 'pause_ms', voice_path: 'voice_id', model_path: 'model',
                  settings_path: 'settings' }.freeze
  ENTRY_KEYS = %w[file text segments voice_id model output_format settings pronunciations alignment noise_windows].freeze

  # Manifest entries keyed by source file name: { 'intro.mp3' => entry }.
  # A file is the flat form ({ "clips": [...] } or an array of entries); a
  # directory holds one JSON per clip named <audio stem>.json, read through map.
  def manifest(path, map: {})
    return {} unless path

    raw = File.directory?(path) ? Dir.glob(File.join(path, '*.json')).sort.map { |f| from_clip_json(f, DEFAULT_MAP.merge(map.compact)) } : flat_entries(path)
    raw.each_with_object({}) do |e, out|
      entry = validate_entry!(e)
      raise UsageError, "manifest names #{entry['file']} twice" if out.key?(entry['file'])

      out[entry['file']] = entry
    end
  end

  def flat_entries(path)
    data = JSON.parse(File.read(path))
    list = data.is_a?(Hash) ? data['clips'] : data
    raise UsageError, "manifest #{path} must be a list of clips or { \"clips\": [...] }" unless list.is_a?(Array)

    list.map { |e| e.is_a?(Hash) ? e.slice(*ENTRY_KEYS).merge('segments' => e['segments'] || [ { 'text' => e['text'], 'pause_ms' => 0 } ]) : e }
  end

  def from_clip_json(file, map)
    data = JSON.parse(File.read(file))
    segments = segments_at(data, map[:text_path], map[:order_key], map[:pause_key])
    { 'file' => data['file'] || "#{File.basename(file, '.json')}.mp3", 'text' => segments.map { |g| g['text'] }.join(' '), 'segments' => segments,
      'voice_id' => dig_path(data, map[:voice_path]), 'model' => dig_path(data, map[:model_path]), 'settings' => dig_path(data, map[:settings_path]),
      'pronunciations' => data['pronunciations'] }.compact
  rescue JSON::ParserError => e
    raise UsageError, "manifest file #{file} is not JSON (#{e.message[0, 60]})"
  end

  def dig_path(data, path)
    return nil unless path

    path.split('.').reduce(data) { |node, key| node.is_a?(Hash) ? node[key] : nil }
  end

  # [{ 'text', 'pause_ms' }] in order. Without `[]` the path names one string.
  def segments_at(data, path, order_key, pause_key)
    head, tail = path.split('[].', 2)
    return [ { 'text' => dig_path(data, path), 'pause_ms' => 0 } ] unless tail

    items = Array(dig_path(data, head))
    items = items.sort_by { |i| [ i.is_a?(Hash) ? i[order_key].to_f : 0 ] }.to_a if order_key
    items.map { |i| { 'text' => dig_path(i, tail), 'pause_ms' => i.is_a?(Hash) ? i[pause_key].to_i : 0 } }
  end

  def validate_entry!(entry)
    raise UsageError, 'a manifest entry is not an object' unless entry.is_a?(Hash)

    name = entry['file'].to_s
    raise UsageError, 'a manifest entry has no file' if name.empty?
    raise UsageError, "manifest entry #{name} has no text" if entry['text'].to_s.strip.empty? || Array(entry['segments']).any? { |g| g['text'].to_s.strip.empty? }
    raise UsageError, "manifest entry #{name} has no voice_id" unless entry['voice_id'].is_a?(String) && !entry['voice_id'].empty?
    raise UsageError, "manifest entry #{name} settings must be an object" unless entry['settings'].nil? || entry['settings'].is_a?(Hash)

    entry.merge('pronunciations' => pronunciation_list(entry['pronunciations'], name)).compact
  end

  # cf:narrate's [{ "text", "say" }] list; a { text => say } object is accepted too.
  def pronunciation_list(value, name)
    return nil if value.nil?

    list = value.is_a?(Hash) ? value.map { |t, say| { 'text' => t, 'say' => say } } : value
    ok = list.is_a?(Array) && list.all? { |p| p.is_a?(Hash) && p['text'].is_a?(String) && p['say'].is_a?(String) }
    raise UsageError, "manifest entry #{name} pronunciations must be [{ text, say }]" unless ok

    list
  end

  def manifest_sha(entries) = entries.empty? ? nil : RoastAudioWords.sha256(entries)

  private_class_method :pick, :check_ids!, :diff_line, :file_ref, :clip, :revoice_one, :tts, :store_take!, :regen_note, :pace_step, :why_not, :revoice_proposal, :flat_entries, :from_clip_json, :segments_at, :validate_entry!, :words_fresh, :judge_fresh, :pending_stage, :blocked_reason, :verdict
end
