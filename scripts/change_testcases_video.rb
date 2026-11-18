#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require_relative 'change_docker'

# `--export video` for the testcases lane: one MP4 per case, from frames the
# case module streamed to its attempt dir while the case ran.
#
# Nothing is buffered in memory on either side. The module keeps only the
# latest screencast frame and writes one JPEG per tick (FPS, at most MAX_WIDTH
# by MAX_HEIGHT) into the mounted attempt dir; Ruby never reads a frame, it
# hands the dir to the pinned FFmpeg image. No narration, no music, no paid
# call.
#
# Disk is budgeted so a recording can never crowd out the evidence a verdict
# rests on. At run start a reserve is set aside for that evidence
# (RESERVE_BASE plus RESERVE_PER_CASE per selected case); recording gets the
# free space left above it, capped at --video-budget-mb, split evenly across the
# cases. Each case's module stops recording at its share, and each encode
# checks free space first. Running out fails the export only, never a case.
module ChangeTestcasesVideo
  MB = 1024 * 1024
  RESERVE_BASE = 64 * MB
  RESERVE_PER_CASE = 8 * MB
  DEFAULT_BUDGET_MB = 2048
  FPS = 5
  MAX_WIDTH = 1280
  MAX_HEIGHT = 800
  TITLE_SECONDS = 2
  ENCODERS = 2
  OUT_NAME = 'out.mp4'

  module_function

  def reserve_bytes(case_count) = RESERVE_BASE + (RESERVE_PER_CASE * case_count)

  # Each case's recording share in bytes, 0 when the disk cannot spare any.
  def per_case_bytes(free_bytes:, case_count:, budget_mb: DEFAULT_BUDGET_MB)
    return 0 if case_count.zero?

    available = [ free_bytes - reserve_bytes(case_count), budget_mb * MB ].min
    [ available / case_count, 0 ].max
  end

  # Free bytes on the volume holding `dir`, from POSIX df.
  def free_bytes(dir)
    out, status = Open3.capture2e('df', '-Pk', dir.to_s)
    return 0 unless status.success?

    out.lines.last.to_s.split[3].to_i * 1024
  end

  # The case's frames (frame-NNNNNN.jpg) in the order they were written.
  def frames(dir) = Dir.glob(File.join(dir, 'frame-*.jpg')).sort

  def frame_bytes(dir) = frames(dir).sum { |path| File.size(path) }

  # Frames of attempts that did not decide the case are dropped once it is
  # final, so the spool holds at most one attempt's frames per case.
  def drop_frames(dir) = frames(dir).each { |path| File.delete(path) }

  # The case's captions: each step's label from when it started until the
  # next one, shifted past the title card.
  def srt(marks, end_ms)
    offset = TITLE_SECONDS * 1000
    marks.each_with_index.map do |mark, index|
      finish = marks[index + 1] ? marks[index + 1]['ms'] : end_ms
      "#{index + 1}\n#{stamp(mark['ms'].to_i + offset)} --> #{stamp([ finish.to_i, mark['ms'].to_i + 200 ].max + offset)}\n" \
        "#{mark['label']}\n"
    end.join("\n")
  end

  def stamp(ms)
    format('%<h>02d:%<m>02d:%<s>02d,%<ms>03d', h: ms / 3_600_000, m: (ms / 60_000) % 60, s: (ms / 1000) % 60, ms: ms % 1000)
  end

  # Lays the title card (TITLE_SECONDS of it) and the frames out as one
  # numbered sequence in `work`, beside the captions, and returns the frame
  # count.
  def stage(attempt_dir, work, marks)
    FileUtils.rm_rf(work)
    FileUtils.mkdir_p(work)
    sequence = []
    title = File.join(attempt_dir, 'title.jpg')
    sequence.concat([ title ] * (TITLE_SECONDS * FPS)) if File.exist?(title)
    recorded = frames(attempt_dir)
    sequence.concat(recorded)
    sequence.each_with_index { |path, index| FileUtils.cp(path, File.join(work, format('%06d.jpg', index + 1))) }
    File.write(File.join(work, 'captions.srt'), srt(marks, (recorded.size * 1000) / FPS))
    sequence.size
  end

  def encode_argv(work)
    ChangeDocker.run_command(
      network: 'none', image: ChangeDocker::FFMPEG_IMAGE, mounts: { work => '/work' },
      args: [ '-y', '-v', 'error', '-framerate', FPS.to_s, '-i', '/work/%06d.jpg', '-i', '/work/captions.srt',
              '-map', '0:v', '-map', '1:s', '-r', FPS.to_s,
              '-vf', "scale=#{MAX_WIDTH}:#{MAX_HEIGHT}:force_original_aspect_ratio=decrease," \
                     "pad=#{MAX_WIDTH}:#{MAX_HEIGHT}:(ow-iw)/2:(oh-ih)/2:white,setsar=1",
              '-c:v', 'libx264', '-crf', '23', '-pix_fmt', 'yuv420p', '-c:s', 'mov_text',
              '-movflags', '+faststart', "/work/#{OUT_NAME}" ]
    )
  end

  # Encodes cases after they finish, ENCODERS at a time whatever the lane's
  # `parallel` is, and records each outcome. `runner` takes an argv and
  # returns [output, status]; `free` returns the free bytes on the run volume.
  class Encoder
    attr_reader :results

    def initialize(reserve:, runner: ->(argv) { Open3.capture2e(*argv) }, free: nil)
      @reserve = reserve
      @runner = runner
      @free = free
      @results = {}
      @lock = Mutex.new
      @queue = Queue.new
      @workers = Array.new(ENCODERS) { Thread.new { work } }
    end

    # Queues one case's encode: its last attempt dir, the mp4 path, and the
    # step marks its module returned.
    def add(key:, attempt_dir:, out:, marks:, stopped: nil)
      @queue << { key: key, attempt_dir: attempt_dir, out: out, marks: Array(marks), stopped: stopped }
    end

    def failed(key, reason) = record(key, 'status' => 'failed', 'reason' => reason)

    def finish
      @queue.close
      @workers.each(&:join)
      @results
    end

    private

    def work
      while (job = @queue.pop)
        record(job[:key], encode(job))
      end
    end

    def encode(job)
      dir = job[:attempt_dir]
      recorded = ChangeTestcasesVideo.frames(dir)
      return { 'status' => 'failed', 'reason' => 'no frames were recorded' } if recorded.empty?

      needed = recorded.sum { |path| File.size(path) } * 2
      if @free && (@free.call - @reserve) < needed
        return { 'status' => 'failed', 'reason' => 'not enough free disk to encode above the evidence reserve' }
      end

      run(job)
    rescue StandardError => e
      { 'status' => 'failed', 'reason' => "encode failed: #{e.message}" }
    ensure
      FileUtils.rm_rf(File.join(dir, 'encode')) if dir
    end

    def run(job)
      work = File.join(job[:attempt_dir], 'encode')
      ChangeTestcasesVideo.stage(job[:attempt_dir], work, job[:marks])
      output, status = @runner.call(ChangeTestcasesVideo.encode_argv(work))
      produced = File.join(work, OUT_NAME)
      unless status.success? && File.file?(produced)
        return { 'status' => 'failed', 'reason' => "ffmpeg failed: #{output.to_s.strip[-300..] || output}" }
      end

      FileUtils.mkdir_p(File.dirname(job[:out]))
      FileUtils.mv(produced, job[:out])
      entry = { 'status' => 'ok', 'path' => job[:out] }
      job[:stopped] ? entry.merge('note' => "recording stopped early: #{job[:stopped]}") : entry
    end

    def record(key, entry) = @lock.synchronize { @results[key] = entry }
  end
end
