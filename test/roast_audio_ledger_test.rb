# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/roast_audio_ledger"

class RoastAudioLedgerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("roast-audio-ledger")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def ledger(cap: 1.0, max: 0.5) = RoastAudioLedger.new(@dir, cap_usd: cap, max_usd: max)

  def bound(usd) = { usd: usd, basis: { provider: "openai", model: "gpt-transcribe", minutes: 1, duration_s: 6.0 } }

  def data = JSON.parse(File.read(File.join(@dir, "spend.json")))

  def test_reserve_refuses_over_the_run_cap_and_the_per_call_ceiling
    l = ledger(cap: 0.1, max: 0.08)
    l.reserve("transcribe", bound(0.06))
    assert_raises(RoastAudioLedger::Refused) { l.reserve("transcribe", bound(0.05)) }
    assert_raises(RoastAudioLedger::Refused) { ledger(cap: 1.0, max: 0.08).reserve("transcribe", bound(0.09)) }
    assert_equal 1, data["entries"].size
  end

  def test_settle_records_the_actual_cost_and_frees_the_difference
    l = ledger
    id = l.reserve("transcribe", RoastAudioLedger.bound("transcribe", model: "gpt-transcribe", duration_s: 6.0))
    e = l.settle(id, { "seconds" => 6.0 })
    assert_equal "settled", e["status"]
    assert_in_delta 0.0045, e["actual_usd"]
    assert_in_delta 0.0045, l.committed
  end

  def test_a_settle_above_its_reservation_halts_and_refuses_the_next_reserve
    l = ledger
    id = l.reserve("judge", { usd: 0.001, basis: { model: "gpt-audio-1.5" } })
    l.settle(id, { "prompt_tokens" => 10_000, "prompt_tokens_details" => { "audio_tokens" => 9000 }, "completion_tokens" => 100 })
    assert data["halted"]
    assert_equal id, data["halted"]["entry"]
    err = assert_raises(RoastAudioLedger::Refused) { l.reserve("transcribe", bound(0.001)) }
    assert_match(/halted/, err.message)
  end

  def test_uncertain_keeps_the_full_reservation_and_release_drops_it
    l = ledger
    a = l.reserve("transcribe", bound(0.2))
    b = l.reserve("transcribe", bound(0.3))
    l.settle(a, nil).then { |e| assert_equal "settled", e["status"] }
    l.uncertain(b)
    assert_in_delta 0.0045 + 0.3, l.committed
    l.release(b)
    assert_in_delta 0.0045, l.committed
  end

  def test_missing_judge_usage_leaves_the_entry_uncertain
    l = ledger
    id = l.reserve("judge", { usd: 0.01, basis: { model: "gpt-audio-1.5" } })
    assert_equal "uncertain", l.settle(id, nil)["status"]
    assert_in_delta 0.01, l.committed
  end

  def test_spend_releases_on_pre_dispatch_and_keeps_uncertain_on_a_later_error
    l = ledger
    missing = Class.new(StandardError)
    assert_raises(missing) do
      l.spend("transcribe", bound(0.2)) do
        raise missing, "no key"
      rescue missing
        raise RoastAudioLedger::PreDispatch, "not sent"
      end
    end
    assert_equal "released", data["entries"].last["status"]
    assert_raises(IOError) { l.spend("transcribe", bound(0.2)) { raise IOError, "reset" } }
    assert_equal "uncertain", data["entries"].last["status"]
    assert_equal "done", l.spend("transcribe", bound(0.1)) { [ "done", {} ] }
  end

  def test_an_unreadable_ledger_refuses
    File.write(File.join(@dir, "spend.json"), "{not json")
    err = assert_raises(RoastAudioLedger::Refused) { ledger.reserve("transcribe", bound(0.01)) }
    assert_match(/unreadable/, err.message)
    File.write(File.join(@dir, "spend.json"), "[]")
    assert_raises(RoastAudioLedger::Refused) { ledger.reserve("transcribe", bound(0.01)) }
  end

  def test_unknown_prices_and_quantities_raise_unbounded_cost
    assert_raises(RoastAudioLedger::UnboundedCost) { RoastAudioLedger.bound("transcribe", model: "whisper-1", duration_s: 6.0) }
    assert_raises(RoastAudioLedger::UnboundedCost) { RoastAudioLedger.bound("transcribe", model: "gpt-transcribe", duration_s: nil) }
    assert_raises(RoastAudioLedger::UnboundedCost) { RoastAudioLedger.bound("judge", model: "gpt-audio-9", duration_s: 6.0, prompt_bytes: 100) }
    assert_raises(RoastAudioLedger::UnboundedCost) { RoastAudioLedger.bound("regen", model: "eleven_v3", chars: Float::NAN) }
  end

  def test_transcription_bounds_whole_minutes
    assert_in_delta 0.0045, RoastAudioLedger.bound("transcribe", model: "gpt-transcribe", duration_s: 6.0)[:usd]
    assert_in_delta 0.009, RoastAudioLedger.bound("transcribe", model: "gpt-transcribe", duration_s: 61.0)[:usd]
  end

  def test_regen_is_bounded_at_the_elevenlabs_estimate_rate
    est = ElevenLabs.estimate(chars: 1234, music_ms: 0, model: "eleven_multilingual_v2")[:tts_usd]
    assert_in_delta est, RoastAudioLedger.bound("regen", model: "eleven_multilingual_v2", chars: 1234)[:usd], 1e-4
  end

  def test_concurrent_processes_never_pass_the_cap_or_lose_an_entry
    lock = File.join(@dir, "spend.lock")
    ledger.read
    inode = File.stat(lock).ino
    pids = Array.new(6) do |n|
      fork do
        l = ledger(cap: 0.5, max: 0.5)
        20.times do |i|
          id = l.reserve("transcribe", bound(0.01))
          case (n + i) % 3
          when 0 then l.settle(id, {})
          when 1 then l.release(id)
          else l.uncertain(id)
          end
        rescue RoastAudioLedger::Refused
          nil
        end
        exit!(0)
      end
    end
    pids.each { |pid| Process.wait(pid) }
    entries = data["entries"]
    assert_equal entries.size, entries.map { |e| e["id"] }.uniq.size
    assert_operator ledger.committed, :<=, 0.5 + 1e-9
    assert_operator entries.size, :>, 40
    assert_equal inode, File.stat(lock).ino, "spend.lock is never replaced"
  end
end
