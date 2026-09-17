#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'digest'

# Tracks which review-eligible files changed during a session, keyed by content
# hash so a file is reviewed once per distinct content, not once per identity or
# turn. A file is enqueued only when its current hash differs from the hash it
# was last reviewed at, so the review -> fix -> re-edit loop converges (find +
# confirm) and any genuinely new change later re-triggers a review. A round cap
# is a loud last resort against a batch that never gets reviewed (a stuck or
# non-compliant loop). It counts consecutive denials of one unchanged batch,
# identified by a fingerprint of the pending (skill, path, hash) tuples; a batch
# that changes starts its own count, and a capped batch un-caps itself the
# moment the pending set changes. Ack still clears the counter outright. State
# lives under ~/.claude/cf/sessions/<id>/; a blank session id is non-persistable.
class ReviewQueue
  CAP = 5

  def initialize(session_id)
    @session_id = session_id.to_s
  end

  # Queue path under skill at the given content hash, unless that exact content
  # was already reviewed under that skill. Keyed by (skill, path) so several
  # skills can review the same file; re-queuing the pair keeps the latest hash.
  def add(skill, path, hash)
    return if !persistable? || reviewed[key(skill, path)] == hash

    rows = entries.reject { |row| row[:skill] == skill && row[:path] == path }
    rows << { skill: skill, path: path, hash: hash }
    write(queue_file, rows.map { |row| "#{row[:skill]}\t#{row[:path]}\t#{row[:hash]}" })
  end

  # Rows still awaiting a review verdict. Read-only: it does not clear the queue,
  # so the gate stays denied until an explicit ack records the verdict.
  def pending = entries

  # Completion signal: mark every queued entry reviewed at its current content
  # hash, then clear the queue. Marking happens here, when a review verdict is in
  # hand, not when the prompt is dispatched, so a push is released only by a
  # finished review and never by the gate merely having fired. Re-editing a file
  # changes its hash, so a stale verdict no longer covers it and it re-queues.
  #
  # Clearing the round counter too is what keeps the cap meaningful: ack clears
  # the counter outright, and the fingerprint means an unrelated batch never
  # inherits another batch's progress toward the cap. Without this a long
  # session of unrelated review cycles would trip the escape valve and silently
  # stop gating; with it, only a batch that is never reviewed (a stuck or
  # non-compliant loop) climbs to the cap.
  def ack
    rows = entries
    mark_reviewed(rows)
    delete(queue_file)
    delete(rounds_file)
    rows
  end

  # A stable identity for a pending batch: the sorted (skill, path, hash)
  # tuples, hashed. Two denials share a fingerprint only when the agent was
  # shown exactly the same files at exactly the same content and did nothing
  # about any of them.
  def self.fingerprint(rows)
    material = rows.map { |row| "#{row[:skill]}\t#{row[:path]}\t#{row[:hash]}" }.sort.join("\n")
    Digest::SHA256.hexdigest(material)[0, 16]
  end

  # Counts consecutive denials of the SAME batch. A batch that differs from the
  # last denied one - new real work, or a partial ack - starts its own count at
  # 1 rather than inheriting the previous batch's progress toward the cap.
  def bump_round(rows = pending)
    fp = self.class.fingerprint(rows)
    count = fp == round_fingerprint ? rounds + 1 : 1
    write(rounds_file, [ "#{count}\t#{fp}" ])
  end

  # Capped only while the batch that tripped the cap is still exactly what is
  # pending. Fix one file, or add a new one, and the fingerprint changes, so
  # review resumes on its own for the new batch. There is no separate uncap.
  def capped?(rows = pending)
    rounds >= CAP && round_fingerprint == self.class.fingerprint(rows)
  end

  def rounds = rounds_line[0].to_i

  def empty? = entries.empty?

  private

  def round_fingerprint = rounds_line[1]

  def rounds_line
    return [] unless persistable? && File.exist?(rounds_file)

    File.read(rounds_file).split("\n").first.to_s.split("\t", 2)
  rescue StandardError
    []
  end

  # Records each entry's content hash as reviewed so identical content does not
  # re-queue. Driven only by ack, when a review verdict is in hand.
  def mark_reviewed(rows)
    return unless persistable?

    map = reviewed
    rows.each { |row| map[key(row[:skill], row[:path])] = row[:hash] }
    write(reviewed_file, map.map { |pair, hash| "#{pair}\t#{hash}" })
  end

  def entries
    read(queue_file).map do |line|
      skill, path, hash = line.split("\t", 3)
      { skill: skill, path: path, hash: hash }
    end
  end

  def reviewed
    read(reviewed_file).to_h do |line|
      skill, path, hash = line.split("\t", 3)
      [ key(skill, path), hash ]
    end
  end

  def key(skill, path) = "#{skill}\t#{path}"

  def read(path)
    return [] unless persistable? && File.exist?(path)

    File.readlines(path, chomp: true).reject(&:empty?)
  end

  def write(path, lines)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, lines.empty? ? '' : "#{lines.join("\n")}\n")
  end

  def delete(path) = (File.delete(path) if persistable? && File.exist?(path))

  def persistable? = !@session_id.empty?

  def dir           = File.join(Dir.home, '.claude', 'cf', 'sessions', @session_id)
  def queue_file    = File.join(dir, 'review-queue')
  def reviewed_file = File.join(dir, 'review-reviewed')
  def rounds_file   = File.join(dir, 'review-rounds')
end
