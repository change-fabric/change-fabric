#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'

# Tracks which review-eligible files changed during a session, keyed by content
# hash so a file is reviewed once per distinct content, not once per identity or
# turn. A file is enqueued only when its current hash differs from the hash it
# was last reviewed at, so the review -> fix -> re-edit loop converges (find +
# confirm) and any genuinely new change later re-triggers a review. A round cap
# is a loud last resort against pathological oscillation. State lives under
# ~/.claude/pst/sessions/<id>/; a blank session id is non-persistable.
class ReviewQueue
  CAP = 5

  def initialize(session_id)
    @session_id = session_id.to_s
  end

  # Queue path under skill at the given content hash, unless that exact content
  # was already reviewed. Dedupes by path, keeping the latest hash.
  def add(skill, path, hash)
    return if !persistable? || reviewed[path] == hash

    rows = entries.reject { |row| row[:path] == path }
    rows << { skill: skill, path: path, hash: hash }
    write(queue_file, rows.map { |row| "#{row[:skill]}\t#{row[:path]}\t#{row[:hash]}" })
  end

  def drain
    rows = entries
    delete(queue_file)
    rows
  end

  # Records each entry's content hash as reviewed so identical content does not
  # re-queue. Call when a review is actually dispatched (or declined at the cap).
  def mark_reviewed(rows)
    return unless persistable?

    map = reviewed
    rows.each { |row| map[row[:path]] = row[:hash] }
    write(reviewed_file, map.map { |path, hash| "#{path}\t#{hash}" })
  end

  def bump_round = write(rounds_file, [ (rounds + 1).to_s ])

  def capped? = rounds >= CAP

  def rounds = persistable? && File.exist?(rounds_file) ? File.read(rounds_file).to_i : 0

  def empty? = entries.empty?

  private

  def entries
    read(queue_file).map do |line|
      skill, path, hash = line.split("\t", 3)
      { skill: skill, path: path, hash: hash }
    end
  end

  def reviewed
    read(reviewed_file).to_h do |line|
      path, hash = line.split("\t", 2)
      [ path, hash ]
    end
  end

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

  def dir           = File.join(Dir.home, '.claude', 'pst', 'sessions', @session_id)
  def queue_file    = File.join(dir, 'review-queue')
  def reviewed_file = File.join(dir, 'review-reviewed')
  def rounds_file   = File.join(dir, 'review-rounds')
end
