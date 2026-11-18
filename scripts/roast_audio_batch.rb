# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

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
  def open(dir, pairs, config_hash:, brief: nil, manifest: nil, max_attempts: nil, new_batch: false)
    ids = check_ids!(pairs)
    old = load(dir)
    if old && !new_batch
      had = old['clips'].map { |c| c['source_id'] }.sort
      raise UsageError, "this selection differs from #{index_path(dir)} (#{diff_line(had, ids.keys.sort)}); pass --new-batch to start over" unless had == ids.keys.sort
    end
    previous = (new_batch ? nil : old)&.fetch('clips')&.to_h { |c| [ c['source_id'], c ] } || {}
    clips = pairs.map { |p| clip(p, previous[source_id(p[:source_audio])], max_attempts) }
    write(dir, { 'config_hash' => config_hash, 'brief' => file_ref(brief), 'manifest' => file_ref(manifest), 'clips' => clips })
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

  private_class_method :pick, :check_ids!, :diff_line, :file_ref, :clip
end
