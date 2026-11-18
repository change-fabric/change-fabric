#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'time'

# The testcases lane's run-scoped evidence directory, `<out>/testcases-<run-id>/`.
#
# It is bind-mounted into the browser container at MOUNT, and each case attempt
# gets `cases/<suite>/<id>/attempt-<n>/` inside it. Ruby writes `start.json`
# before the call; the case module checkpoints a trace file per step (with the
# console errors and failed requests seen during it) and its screenshots as it
# goes, by downloading them into that dir, because the function sandbox has no
# file system of its own. Ruby writes `result.json` from what the call returned.
#
# So an attempt whose call never returned (killed on its budget, a browser
# crash, a transport error) still leaves `start.json` and every checkpoint it
# reached, and is recorded as partial_evidence instead of being lost.
class ChangeTestcasesEvidence
  MOUNT = '/cf-run'
  # Created world-writable: the browser in the container writes into these
  # dirs as its own user, and a dir it had to create itself could be one the
  # host cannot read back.
  SHARED_MODE = 0o777
  RESULTS_FILE = 'case-results.jsonl'

  Attempt = Struct.new(:host_dir, :container_dir, keyword_init: true) do
    def js = { dir: container_dir }
  end

  def self.prepare(out_dir, run_id)
    dir = File.join(out_dir, "testcases-#{run_id}")
    FileUtils.mkdir_p(dir)
    File.chmod(SHARED_MODE, dir)
    dir
  end

  attr_reader :root

  def initialize(root)
    @root = root
  end

  # A filesystem-safe name that stays unique: when sanitizing changed the
  # text, a short digest of the original is appended, so `a/b` and `a_b`
  # never share a dir.
  def self.slug(text)
    raw = text.to_s
    safe = raw.gsub(/[^A-Za-z0-9._-]/, '_')
    safe == raw ? safe : "#{safe}-#{Digest::SHA256.hexdigest(raw)[0, 8]}"
  end

  def open_attempt(item, number, start)
    relative = File.join('cases', self.class.slug(item.suite), self.class.slug(item.id), "attempt-#{number}")
    host_dir = shared_dir(relative)
    File.write(File.join(host_dir, 'start.json'), "#{JSON.pretty_generate(start)}\n")
    Attempt.new(host_dir: host_dir, container_dir: File.join(MOUNT, relative))
  end

  # Finishes one attempt's dir from the record its call returned. A call that
  # never returned a payload becomes partial_evidence, carrying the steps it
  # checkpointed. A queue rejection was never an attempt, so its dir goes.
  def close_attempt(attempt, record)
    return record unless attempt
    # A terminated call, resumed or not, is rebuilt from its checkpoints. Only
    # a call that never ran is discarded; a resume that was rejected
    # after the first call ran keeps everything that call checkpointed.
    return discard(attempt, record) if record.nil? || (record['queueFull'] && !record['resumed'])

    record = partial(attempt, record) if record['callError'] && !(record['resumed'] && record['queueFull'])
    record = record.merge('evidenceDir' => attempt.host_dir)
    write_screenshots(attempt, record)
    name = record['partialEvidence'] ? 'termination.json' : 'result.json'
    File.write(File.join(attempt.host_dir, name), "#{JSON.pretty_generate(without_images(record))}\n")
    record
  end

  # The per-step checkpoints the case module wrote, in step order. A resumed
  # call rewrites the steps it replayed; the later file wins.
  def checkpointed_steps(dir)
    Dir.glob(File.join(dir, 'step-*.json')).sort.each_with_object({}) do |path, steps|
      entry = JSON.parse(File.read(path))
      steps[entry.dig('record', 'index').to_i] = entry['record']
    rescue JSON::ParserError
      next
    end.sort.map(&:last)
  end

  def write_records(records)
    File.write(File.join(@root, RESULTS_FILE), records.map { |record| "#{record.to_json}\n" }.join)
  end

  private

  def shared_dir(relative)
    path = @root
    relative.split('/').each do |part|
      path = File.join(path, part)
      next if Dir.exist?(path)

      begin
        Dir.mkdir(path)
        File.chmod(SHARED_MODE, path)
      rescue Errno::EEXIST
        next # a parallel case made it first
      end
    end
    path
  end

  def discard(attempt, record)
    FileUtils.rm_rf(attempt.host_dir)
    record
  end

  def partial(attempt, record)
    steps = checkpointed_steps(attempt.host_dir)
    record.merge('ok' => false, 'partialEvidence' => true, 'steps' => steps)
  end

  # A `screenshot` step's image comes back in its step record; it is kept as
  # a file beside the trace rather than dropped.
  def write_screenshots(attempt, record)
    Array(record['steps']).each do |step|
      next unless step['screenshot'].is_a?(String)

      name = "shot-#{format('%04d', step['index'].to_i + 1)}-#{self.class.slug(step['name'] || 'screenshot')}.png"
      File.binwrite(File.join(attempt.host_dir, name), Base64.decode64(step['screenshot']))
    end
  end

  def without_images(record)
    steps = Array(record['steps']).map { |step| step.is_a?(Hash) ? step.except('screenshot') : step }
    record.merge('steps' => steps)
  end
end
