# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'walkthrough_captions'

# The word check for cf:roast --audio. This slice holds alignment provenance:
# an ElevenLabs alignment is trusted only when its sidecar binds it to the
# exact audio bytes and to its own content. The gate uses the bound word spans
# to find expected non-speech regions; the word diff builds on the same check.
module RoastAudioWords
  module_function

  # Sorted-key JSON, so a hash of it does not depend on key order.
  def canonical(value)
    case value
    when Hash then "{#{value.keys.map(&:to_s).sort.map { |k| "#{JSON.generate(k)}:#{canonical(value[k] || value[k.to_sym])}" }.join(',')}}"
    when Array then "[#{value.map { |v| canonical(v) }.join(',')}]"
    else JSON.generate(value)
    end
  end

  def sha256(value) = Digest::SHA256.hexdigest(canonical(value))

  # { status: 'verified'|'unbound'|'mismatch'|'absent', alignment:, generator: }.
  # Verified needs a sidecar whose audio_sha256 is the given audio's digest and
  # whose alignment_sha256 is the digest of its own alignment's canonical JSON.
  # A bare alignment JSON (no binding) is unbound.
  def provenance(path, audio_sha256:)
    return { status: 'absent' } unless path && File.file?(path)

    data = JSON.parse(File.read(path))
    return { status: 'unbound' } unless data.is_a?(Hash) && data['alignment'].is_a?(Hash) && data['audio_sha256']
    return { status: 'mismatch', reason: 'audio_sha256 is not this audio' } unless data['audio_sha256'] == audio_sha256
    return { status: 'mismatch', reason: 'alignment_sha256 does not match its alignment' } unless data['alignment_sha256'] == sha256(data['alignment'])

    { status: 'verified', alignment: data['alignment'], generator: data['generator'] }
  rescue JSON::ParserError
    { status: 'unbound', reason: 'alignment file is not JSON' }
  end

  # Word spans from a verified alignment, shifted by the gate's trim delta.
  def spans(alignment, offset_ms: 0) = WalkthroughCaptions.word_spans(alignment, offset_ms: offset_ms)
end
