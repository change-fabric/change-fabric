# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

# Run directories under ~/.claude/cf/research/<slug>/<run-id>/, the run.json
# state machine, cache lookup and the --out-dir copy. Never inside the repo.
# A run.json write is atomic (temp file, then rename); a run dir is never
# overwritten.
module DeepResearchStore
  STATES = %w[pending submitting running cancel_requested ingested done failed canceled].freeze
  TRANSITIONS = {
    'pending' => %w[ingested failed],
    'submitting' => %w[running failed canceled],
    'running' => %w[cancel_requested ingested failed],
    'cancel_requested' => %w[canceled failed],
    'ingested' => %w[done failed],
    'done' => [], 'failed' => [], 'canceled' => []
  }.freeze
  DEFAULT_MAX_AGE_DAYS = 30

  class Error < StandardError; end

  module_function

  def root = ENV['CF_RESEARCH_ROOT'] || File.join(Dir.home, '.claude', 'cf', 'research')

  def new_id = "dr-#{SecureRandom.uuid}"

  def slug_for(text)
    slug = text.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')[0, 40].to_s.sub(/-+\z/, '')
    slug.empty? ? 'research' : slug
  end

  def valid_slug?(slug) = slug.to_s.match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/)

  def run_dir(slug, id) = File.join(root, slug, id)

  def create(record, prompt)
    dir = run_dir(record['slug'], record['id'])
    raise Error, "run dir already exists: #{dir}" if File.exist?(dir)

    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'prompt.md'), prompt)
    write(dir, record)
    dir
  end

  def read(dir) = JSON.parse(File.read(File.join(dir, 'run.json')))

  def write(dir, record)
    final = File.join(dir, 'run.json')
    tmp = "#{final}.tmp-#{Process.pid}"
    File.write(tmp, "#{JSON.pretty_generate(record)}\n")
    File.rename(tmp, final)
  end

  def transition(dir, to, extra = {})
    record = read(dir)
    from = record['state']
    raise Error, "cannot move run #{record['id']} from #{from} to #{to}" unless TRANSITIONS.fetch(from, []).include?(to)

    record = record.merge(extra).merge('state' => to)
    write(dir, record)
    record
  end

  def all
    Dir.glob(File.join(root, '*', 'dr-*', 'run.json')).sort.filter_map do |path|
      dir = File.dirname(path)
      [ dir, read(dir) ]
    rescue JSON::ParserError
      nil
    end
  end

  def find(id) = all.find { |_dir, rec| rec['id'] == id }

  def report_path(dir) = File.join(dir, 'report.json')

  # A done run with the same cache key, created within max_age days.
  def cached(cache_key, max_age_days: DEFAULT_MAX_AGE_DAYS, now: Time.now.utc)
    hits = all.select do |dir, rec|
      rec['state'] == 'done' && rec['cache_key'] == cache_key && File.exist?(report_path(dir)) &&
        now - Time.parse(rec['created_at']) <= max_age_days * 86_400
    end
    hits.max_by { |_dir, rec| rec['created_at'] }&.then { |dir, _| report_path(dir) }
  end

  # An already ingested run holding this exact PDF, with a finished report.
  def ingested_pdf(sha256)
    all.find { |dir, rec| rec['pdf_sha256'] == sha256 && rec['state'] == 'done' && File.exist?(report_path(dir)) }
  end

  def copy_out(dir, out_dir, names)
    FileUtils.mkdir_p(out_dir)
    names.each { |n| FileUtils.cp(File.join(dir, n), File.join(out_dir, n)) if File.exist?(File.join(dir, n)) }
  end
end
