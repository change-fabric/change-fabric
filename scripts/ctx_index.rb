#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'yaml'
require_relative 'ctx_paths'
require_relative 'skill_registry'

# Regenerates INDEX.md, one markdown link line per live doc, mirroring the
# harness MEMORY.md index. The index is cheap to load at SessionStart and is
# always derived from the doc set, never hand-edited.
module CtxIndex
  HEADER = "# Context index\n"

  def self.rebuild(store_dir)
    lines = live_docs(store_dir).map { |path, meta| line(meta, relpath(store_dir, path)) }
    write_index(store_dir, lines)
  end

  # [path, frontmatter] for every parseable doc across the live classes, sorted
  # by path so the index is stable.
  def self.live_docs(store_dir)
    CtxPaths::CLASSES.flat_map do |klass|
      Dir.glob(File.join(store_dir, klass, '*.md')).sort.filter_map do |path|
        meta = frontmatter(path)
        meta && [ path, meta ]
      end
    end
  end

  def self.line(meta, rel) = "- [#{meta['name']}](#{rel}) - #{meta['description']}"

  def self.frontmatter(path)
    front, = SkillRegistry::Frontmatter.split(File.read(path))
    meta = front && YAML.safe_load(front)
    meta.is_a?(Hash) ? meta : nil
  rescue StandardError
    nil
  end

  def self.relpath(store_dir, path) = path.delete_prefix("#{store_dir}/")

  def self.write_index(store_dir, lines)
    body = lines.empty? ? HEADER : "#{HEADER}\n#{lines.join("\n")}\n"
    dest = File.join(store_dir, 'INDEX.md')
    FileUtils.mkdir_p(store_dir)
    tmp = "#{dest}.tmp"
    File.write(tmp, body)
    File.rename(tmp, dest)
  end
end
