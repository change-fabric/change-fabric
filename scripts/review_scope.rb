#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require_relative 'skill_registry'

# Filters queued (skill, path) rows down to those a skill still claims against the
# final tree. Enqueue is structural (gates skipped) so a file authored before its
# require marker still enters the queue; here, at review time, each row is judged
# by its file's current repo: an exclude marker now present, or a require marker
# still absent, drops the row. The root is resolved per file the same way
# skill_inject resolves it, and an unresolved root never suppresses.
module ReviewScope
  module_function

  def covered(entries, registry)
    by_name = registry.to_h { |skill| [ skill.name, skill ] }
    roots = {}
    entries.select do |entry|
      skill = by_name[entry[:skill]]
      next true if skill.nil? # unknown skill: keep it so the review still flags it

      dir = File.dirname(entry[:path])
      root = roots.key?(dir) ? roots[dir] : (roots[dir] = repo_root(dir))
      !skill.gated?(root)
    end
  end

  def repo_root(dir)
    out, status = Open3.capture2e('git', '-C', dir, 'rev-parse', '--show-toplevel')
    status&.success? ? out.strip : nil
  rescue StandardError
    nil
  end
end
