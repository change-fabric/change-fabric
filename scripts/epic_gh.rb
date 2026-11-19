#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'plan_phase_trailer'

# The only place epic_status (and later epic_drift) shells out to gh.
# EpicGh::Cli makes the real calls; EpicGh::Fake replays fixture JSON so
# tests never touch the network. Both memoize `pr_view` per instance, so one
# run makes at most one `gh pr view` per PR.
module EpicGh
  class Error < StandardError; end

  class Cli
    def initialize
      @pr_view_cache = {}
    end

    # repo is "owner/name"; number is a PR number. Returns a Hash with
    # state, mergedAt, files, url, number.
    def pr_view(repo, number)
      key = [ repo, number ]
      return @pr_view_cache[key] if @pr_view_cache.key?(key)

      out, err, status = Open3.capture3('gh', 'pr', 'view', number.to_s, '--repo', repo,
                                         '--json', 'state,mergedAt,files,url,number')
      raise Error, "gh pr view #{repo}##{number}: #{err.to_s.strip}" unless status.success?

      @pr_view_cache[key] = JSON.parse(out)
    rescue JSON::ParserError => e
      raise Error, "gh pr view #{repo}##{number}: bad json (#{e.message})"
    rescue SystemCallError => e
      raise Error, "gh pr view #{repo}##{number}: #{e.message}"
    end

    # Every open-or-closed PR in `repo` whose body carries the
    # `Plan-Phase: <ref>` trailer. Returns an array of PR numbers. The search
    # is full text, so a body that only mentions the ref in prose also
    # matches; each candidate's body is parsed and kept only when its trailer
    # line names `ref`.
    def pr_search_trailer(repo, ref)
      query = "\"Plan-Phase: #{ref}\" in:body"
      out, err, status = Open3.capture3('gh', 'pr', 'list', '--repo', repo, '--state', 'all',
                                         '--search', query, '--json', 'number,body')
      raise Error, "gh pr list #{repo} #{ref}: #{err.to_s.strip}" unless status.success?

      JSON.parse(out).select { |row| PlanPhaseTrailer.parse(row['body']) == ref }.map { |row| row['number'] }
    rescue JSON::ParserError => e
      raise Error, "gh pr list #{repo} #{ref}: bad json (#{e.message})"
    rescue SystemCallError => e
      raise Error, "gh pr list #{repo} #{ref}: #{e.message}"
    end
  end

  # Replays canned fixture JSON instead of calling gh. Layout under `dir`:
  #   pr_view/<repo slugged>/<number>.json   (one gh pr view response)
  #   pr_search/<repo slugged>/<ref slugged>.json  (an array of PR numbers)
  # A missing pr_search fixture reads as no matches; a missing pr_view
  # fixture is a fixture bug and raises, matching a real gh error.
  class Fake
    def initialize(dir)
      @dir = dir
      @pr_view_cache = {}
    end

    def pr_view(repo, number)
      key = [ repo, number ]
      return @pr_view_cache[key] if @pr_view_cache.key?(key)

      path = File.join(@dir, 'pr_view', slug(repo), "#{number}.json")
      raise Error, "no fixture at #{path}" unless File.file?(path)

      @pr_view_cache[key] = JSON.parse(File.read(path))
    end

    def pr_search_trailer(repo, ref)
      path = File.join(@dir, 'pr_search', slug(repo), "#{slug(ref)}.json")
      return [] unless File.file?(path)

      JSON.parse(File.read(path))
    end

    private

    def slug(value) = value.to_s.gsub(/[^A-Za-z0-9._-]+/, '-')
  end
end
