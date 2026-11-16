#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'

# Picks which review queue an event's work belongs to. Subagents share their
# parent's session_id, so keying by session alone pools every agent's edits into
# the coordinator's queue and blocks the coordinator on work it never did. The
# key narrows to the agent when the payload names one, else to the agent
# worktree the edit landed in, else it is the coordinator's own session id.
module ReviewKey
  module_function

  WORKTREES = '/.claude/worktrees/'

  def for(event, path: nil)
    session = event['session_id'].to_s
    return session if session.empty?

    agent = event['agent_id'].to_s
    return "#{session}:#{agent}" unless agent.empty?

    slug = worktree_slug(path || event['cwd'])
    slug ? "#{session}@#{slug}" : session
  end

  # Every queue this session owns on disk: its own plus each agent and worktree
  # key. Returned as directory names, which ReviewQueue accepts unchanged.
  def keys_for_session(session_id)
    base = dir_name(session_id)
    return [] if base.empty?

    root = File.join(Dir.home, '.claude', 'cf', 'sessions')
    names = Dir.exist?(root) ? Dir.children(root) : []
    names.select { |name| name == base || name.start_with?("#{base}_", "#{base}@") }.sort
  rescue StandardError
    []
  end

  # The on-disk directory name for a key: anything outside a safe set becomes
  # an underscore, so session:agent maps to session_agent.
  def dir_name(key) = key.to_s.gsub(/[^A-Za-z0-9._@-]/, '_')

  def agent_tree?(path) = path.to_s.include?(WORKTREES)

  # A row the coordinator rooted at `root` owns: under its tree and not in an
  # agent worktree nested below it. With no root, any non-worktree path.
  # Both sides are compared by real path, so a checkout reached through a
  # symlink still owns its rows.
  def own_tree?(path, root)
    return !agent_tree?(path) if root.to_s.empty?

    real = real_path(path)
    real_root = real_path(root)
    real.start_with?("#{real_root}/") && !real.delete_prefix(real_root).include?(WORKTREES)
  end

  # The physical path, resolving the deepest existing ancestor so a deleted
  # file still normalizes.
  def real_path(path)
    path = File.expand_path(path.to_s)
    head = path
    head = File.dirname(head) until File.exist?(head) || head == File.dirname(head)
    File.realpath(head) + path.delete_prefix(head)
  rescue StandardError
    path
  end

  def worktree_slug(path)
    root = toplevel(path)
    return unless root&.include?(WORKTREES)

    File.basename(root)
  end

  # The git toplevel of a file or directory; nil on any failure.
  def toplevel(path)
    return if path.to_s.empty?

    dir = File.directory?(path) ? path : File.dirname(path)
    out, status = Open3.capture2e('git', '-C', dir, 'rev-parse', '--show-toplevel')
    status&.success? ? out.strip : nil
  rescue StandardError
    nil
  end
end
