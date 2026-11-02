#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'ctx_paths'
require_relative 'plan_paths'

# Deterministic half of cf:imagine: where a working directory lives (outside
# git, in a per-user store) and what number the next committed creative record
# takes under docs/creative. The model decides the words; this module reports
# the facts. It never writes a file and never deletes one.
module ImaginePaths
  class DuplicateNumber < StandardError; end

  RECORD_NAME = /\A(\d{4})-.+\.md\z/
  RECORD_DIR = File.join('docs', 'creative')

  def self.default_root = File.join(CtxPaths.expected_home, '.claude', 'cf', 'imagine')

  def self.root
    env = ENV['CF_IMAGINE_ROOT'].to_s
    env.empty? ? default_root : File.expand_path(env)
  end

  def self.resolve(area:, slug:)
    slug = PlanPaths.slugify(slug)
    dir = File.join(root, area.to_s, slug)
    {
      root:, root_tilde: PlanPaths.tildeize(root),
      area: area.to_s, slug:,
      dir:, dir_tilde: PlanPaths.tildeize(dir), exists: Dir.exist?(dir)
    }
  end

  # Highest existing record number plus one, zero-padded to four digits.
  # Two records sharing a number is a conflict a human must renumber.
  def self.next_record(repo:)
    dir = File.join(repo.to_s, RECORD_DIR)
    return '0001' unless Dir.exist?(dir)

    by_number = Dir.children(dir).sort.filter_map do |name|
      match = RECORD_NAME.match(name)
      [ match[1], name ] if match
    end.group_by(&:first)
    dupes = by_number.select { |_, entries| entries.size > 1 }
    unless dupes.empty?
      files = dupes.values.flatten(1).map(&:last)
      raise DuplicateNumber, "duplicate record numbers in #{dir}: #{files.join(', ')}"
    end

    format('%04d', (by_number.keys.map(&:to_i).max || 0) + 1)
  end

  module CLI
    USAGE = 'usage: imagine_paths.rb resolve --slug S [--area A] | next-record [--repo DIR]'

    def self.run(argv, out: $stdout)
      verb, *rest = argv
      flags = PlanPaths::CLI.parse(rest)
      case verb
      when 'resolve' then resolve(flags, out)
      when 'next-record' then next_record(flags, out)
      else
        out.puts(USAGE)
        exit 2
      end
    end

    def self.resolve(flags, out)
      area = flags['area'] || PlanPaths.infer_area(cwd: Dir.pwd)
      if area.nil? || flags['slug'].to_s.empty?
        out.puts(JSON.generate('error' => 'area_or_slug_unresolved'))
        exit 2
      end
      out.puts(JSON.generate(ImaginePaths.resolve(area:, slug: flags['slug'])))
    end

    def self.next_record(flags, out)
      number = ImaginePaths.next_record(repo: flags['repo'] || '.')
      out.puts(JSON.generate('number' => number, 'dir' => RECORD_DIR))
    rescue DuplicateNumber => e
      warn(e.message)
      exit 1
    end
  end
end

ImaginePaths::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
