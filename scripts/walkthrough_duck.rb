# frozen_string_literal: true

# Music bed ducking under narration, shared by every walkthrough mix. A duck
# span is { start_ms:, end_ms:, db:, attack_ms:, release_ms: } (the ramps are
# optional and default below). The bed ramps down over attack_ms ending at
# start_ms, so it is fully down when speech begins, holds at db, then ramps
# back up over release_ms after end_ms. Ramps are linear in dB, which is what
# the ear hears as an even fade. Spans whose gap is shorter than the release
# of one plus the attack of the next merge, so the bed does not pump between
# close lines.
module WalkthroughDuck
  DEFAULT_DB = -8
  DEFAULT_ATTACK_MS = 300
  DEFAULT_RELEASE_MS = 500
  RAMP_MS = (0..2000)
  # Folded into the manifest so a change to the duck shape re-assembles
  # renders cached under an older one (1 was the hard step).
  VERSION = 2

  module_function

  def attack(span) = (span[:attack_ms] || DEFAULT_ATTACK_MS).to_i

  def release(span) = (span[:release_ms] || DEFAULT_RELEASE_MS).to_i

  # Sorted, merged spans. A merged span keeps the deeper level, the first
  # span's attack and the last span's release.
  def merge(spans)
    spans.sort_by { |s| s[:start_ms] }.each_with_object([]) do |span, out|
      prev = out.last
      if prev && span[:start_ms] - prev[:end_ms] < release(prev) + attack(span)
        last = span[:end_ms] >= prev[:end_ms] ? span : prev
        out[-1] = prev.merge(end_ms: last[:end_ms], db: [ prev[:db], span[:db] ].min, release_ms: release(last))
      else
        out << span.merge(attack_ms: attack(span), release_ms: release(span))
      end
    end
  end

  # The FFmpeg volume expression (use with eval=frame): gain 1 outside every
  # span, 10^(dB(t)/20) inside, where dB(t) is the sum of one trapezoid per
  # merged span. Merged spans never share a ramp, so the sum is exact. The
  # attack is clamped at t=0 and the release at total_ms.
  def expression(spans, total_ms: nil)
    terms = merge(spans).map { |s| term(s, total_ms) }
    terms.empty? ? '1' : "pow(10,(#{terms.join('+')})/20)"
  end

  def term(span, total_ms)
    from = [ span[:start_ms] - span[:attack_ms], 0 ].max
    to = span[:end_ms] + span[:release_ms]
    at_end = total_ms && to >= total_ms
    to = [ to, total_ms ].min if total_ms
    arms = []
    # A zero ramp away from either edge is a 1 ms step, never an open end.
    arms << "(t-#{sec(from)})/#{sec([ span[:start_ms] - from, 1 ].max)}" if from.positive? || span[:start_ms] > from
    arms << "(#{sec(to)}-t)/#{sec([ to - span[:end_ms], 1 ].max)}" unless at_end && to <= span[:end_ms]
    ramp = case arms.size
    when 0 then '1'
    when 1 then "clip(#{arms[0]},0,1)"
    else "clip(min(#{arms.join(',')}),0,1)"
    end
    "#{format('%.2f', span[:db].to_f)}*#{ramp}"
  end

  def sec(ms) = format('%.3f', ms / 1000.0)
end
