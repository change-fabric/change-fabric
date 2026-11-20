#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'
require_relative 'deep_research_parse'
require_relative 'deep_research_pdf'
require_relative 'deep_research_prompt'
require_relative 'deep_research_schema'
require_relative 'deep_research_store'
require_relative 'deep_research_verify'
require_relative 'incident_report'
require_relative 'sensitive_terms'

# cf:deep-research, manual backend. `prompt` writes a ChatGPT deep research
# prompt and a pending run, then ends with exit 6 so the agent stops and waits
# for Patrick to attach the exported PDF. `ingest` parses that PDF into
# report.json. `status` lists runs. Exit codes: 0 ok, 2 usage, schema or
# refusal, 3 provider failure, 6 pending (awaiting Patrick).
module DeepResearch
  SCRIPT_VERSION = '1'
  MANUAL_MODEL = 'chatgpt-web'
  OK = 0
  REFUSED = 2
  PENDING = 6

  # Raised for a refusal; carries the exit code.
  class Refusal < StandardError
    attr_reader :code

    def initialize(message, code = REFUSED)
      super(message)
      @code = code
    end
  end

  class CLI
    def self.run(argv, out: $stdout, err: $stderr, extractor: nil)
      new(out, err, extractor).run(argv)
    end

    def initialize(out, err, extractor)
      @out = out
      @err = err
      @extractor = extractor
    end

    def run(argv)
      command = argv.first
      args = argv.drop(1)
      case command
      when 'prompt' then prompt(args)
      when 'ingest' then ingest(args)
      when 'status' then status(args)
      else usage
      end
    rescue Refusal => e
      @err.puts("deep_research: #{e.message}")
      e.code
    rescue OptionParser::ParseError, DeepResearchPrompt::Error, DeepResearchStore::Error, DeepResearchPdf::Error => e
      @err.puts("deep_research: #{e.message}")
      REFUSED
    end

    private

    def usage
      @err.puts('usage: deep_research.rb prompt|ingest|status (see skills/deep-research)')
      REFUSED
    end

    def prompt(args)
      opts = { contexts: [], max_age: DeepResearchStore::DEFAULT_MAX_AGE_DAYS }
      OptionParser.new do |o|
        o.on('--question TEXT') { |v| opts[:question] = v }
        o.on('--question-file PATH') { |v| opts[:question] = File.read(v) }
        o.on('--context PATH') { |v| opts[:contexts] << v }
        o.on('--slug SLUG') { |v| opts[:slug] = v }
        o.on('--out-dir DIR') { |v| opts[:out_dir] = v }
        o.on('--max-age DAYS', Integer) { |v| opts[:max_age] = v }
        o.on('--copy') { opts[:copy] = true }
        o.on('--refresh') { opts[:refresh] = true }
      end.parse!(args)
      question = opts[:question].to_s.strip
      raise Refusal, 'prompt needs --question or --question-file' if question.empty?

      slug = opts[:slug] || DeepResearchStore.slug_for(question)
      raise Refusal, "bad slug #{slug.inspect}" unless DeepResearchStore.valid_slug?(slug)

      contexts = opts[:contexts].map { |path| [ File.basename(path), File.read(path) ] }
      draft = DeepResearchPrompt.render(question: question, contexts: contexts)
      refuse_sensitive(draft)
      key = DeepResearchPrompt.cache_key(question: question, contexts: contexts, backend: 'manual', model: MANUAL_MODEL)
      unless opts[:refresh]
        hit = DeepResearchStore.cached(key, max_age_days: opts[:max_age])
        return cached(hit) if hit
      end
      write_pending(question, contexts, slug, key, opts)
    end

    def cached(path)
      @out.puts("Cached report: #{path}")
      OK
    end

    def refuse_sensitive(text)
      hits = SensitiveTerms.matched([ text ], SensitiveTerms.load)
      raise Refusal, "prompt contains a sensitive term (#{hits.join(', ')}); nothing written" unless hits.empty?
    end

    def write_pending(question, contexts, slug, key, opts)
      id = DeepResearchStore.new_id
      text = DeepResearchPrompt.render(question: question, contexts: contexts, run_id: id)
      record = { 'id' => id, 'slug' => slug, 'state' => 'pending', 'backend' => 'manual', 'model' => MANUAL_MODEL,
                 'question' => question, 'prompt_sha256' => DeepResearchPrompt.sha256(text), 'cache_key' => key,
                 'created_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'), 'response_id' => nil,
                 'pdf_sha256' => nil, 'script_version' => SCRIPT_VERSION }
      dir = DeepResearchStore.create(record, text)
      DeepResearchStore.copy_out(dir, opts[:out_dir], %w[prompt.md]) if opts[:out_dir]
      copied = opts[:copy] && pbcopy(text)
      path = File.join(DeepResearchStore.root, slug, id, 'prompt.md').sub(Dir.home, '~')
      @out.puts("Run id: #{id}")
      @out.puts("Paste #{path} into ChatGPT deep research, export the report as PDF, then attach it here (or give its absolute path).#{' The prompt is on your clipboard.' if copied}")
      PENDING
    end

    def pbcopy(text)
      _out, status = Open3.capture2('pbcopy', stdin_data: text)
      status.success?
    rescue Errno::ENOENT
      false
    end

    def ingest(args)
      opts = {}
      OptionParser.new do |o|
        o.on('--run ID') { |v| opts[:run] = v }
        o.on('--pdf PATH') { |v| opts[:pdf] = v }
        o.on('--out-dir DIR') { |v| opts[:out_dir] = v }
      end.parse!(args)
      raise Refusal, 'ingest needs --run ID and --pdf ABSOLUTE_PATH' unless opts[:run] && opts[:pdf]
      raise Refusal, "pdf path must be absolute: #{opts[:pdf]}" unless opts[:pdf].start_with?('/')
      raise Refusal, "no such file: #{opts[:pdf]}" unless File.file?(opts[:pdf])

      dir, record = DeepResearchStore.find(opts[:run])
      raise Refusal, "unknown run #{opts[:run]}" unless dir

      sha = Digest::SHA256.file(opts[:pdf]).hexdigest
      if (dup = DeepResearchStore.ingested_pdf(sha))
        @out.puts("Already ingested: #{DeepResearchStore.report_path(dup.first)}")
        return OK
      end
      raise Refusal, "run #{record['id']} is #{record['state']}, not pending" unless record['state'] == 'pending'

      finish_ingest(dir, record, opts, sha)
    end

    def finish_ingest(dir, record, opts, sha)
      xml_path = File.join(dir, 'raw.xml.tmp')
      xml = extract(opts[:pdf], xml_path)
      refuse_secrets(DeepResearchParse.text(xml), xml_path)
      check_binding(xml, record)
      File.rename(xml_path, File.join(dir, 'raw.xml'))
      FileUtils.cp(opts[:pdf], File.join(dir, 'report.pdf'))
      record = DeepResearchStore.transition(dir, 'ingested', 'pdf_sha256' => sha)
      report = build_report(record, DeepResearchParse.parse(xml), sha)
      errors = DeepResearchSchema.validate(report)
      unless errors.empty?
        DeepResearchStore.transition(dir, 'failed')
        raise Refusal, "report failed validation: #{errors.first(5).join('; ')}"
      end
      File.write(DeepResearchStore.report_path(dir), "#{JSON.pretty_generate(report)}\n")
      DeepResearchStore.transition(dir, 'done')
      DeepResearchStore.copy_out(dir, opts[:out_dir], %w[report.json prompt.md]) if opts[:out_dir]
      report['diagnostics'].uniq.each { |d| @err.puts("diagnostic: #{d}") }
      @out.puts("Report: #{DeepResearchStore.report_path(dir)}")
      OK
    end

    def extract(pdf, xml_path)
      DeepResearchPdf.extract(pdf, xml_path, extractor: @extractor || DeepResearchPdf::HostExtractor.new)
    end

    # Names the kind of secret, never the value. The extracted xml is removed.
    def refuse_secrets(text, xml_path)
      kinds = IncidentReport::SECRET_PATTERNS.select { |_kind, re| text.match?(re) }.keys
      return if kinds.empty?

      FileUtils.rm_f(xml_path)
      raise Refusal, "ingested text contains a secret pattern (#{kinds.join(', ')}); nothing kept"
    end

    # Binding rests on the explicit --run flag: a ChatGPT export holds the
    # report only, not the prompt, so the run id is normally absent. Both
    # checks here are advisory warnings, never refusals.
    def check_binding(xml, record)
      other = DeepResearchParse.text(xml).scan(/dr-\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/).uniq - [ record['id'] ]
      @err.puts("warning: this PDF names a different run (#{other.join(', ')}); ingesting as #{record['id']} per --run") if other.any?
      found = DeepResearchParse.lines(xml).filter_map { |l| l.text[DeepResearchParse::HEADING_RE, 1]&.downcase }
      missing = DeepResearchParse::HEADINGS - found
      @err.puts("warning: report headings do not match the skeleton (missing: #{missing.join(', ')})") if missing.any?
    end

    def build_report(record, parsed, sha)
      report = {
        'schema_version' => DeepResearchSchema::VERSION, 'id' => record['id'], 'question' => record['question'],
        'backend' => record['backend'], 'model' => record['model'], 'created_at' => record['created_at'],
        'prompt_sha256' => record['prompt_sha256'], 'summary' => parsed[:summary],
        'findings' => parsed[:findings], 'sources' => parsed[:sources], 'citations' => parsed[:citations],
        'diagnostics' => parsed[:diagnostics], 'output_text' => nil, 'cost' => { 'subscription' => true },
        'provenance' => { 'prompt_sha256' => record['prompt_sha256'], 'backend' => record['backend'],
                          'model' => record['model'], 'pdf_sha256' => sha, 'response_id' => nil, 'from_run' => nil,
                          'date' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'), 'script_version' => SCRIPT_VERSION,
                          'link_annotations' => parsed[:link_annotations] }
      }
      DeepResearchVerify.annotate(report)
    end

    def status(args)
      id = nil
      OptionParser.new { |o| o.on('--run ID') { |v| id = v } }.parse!(args)
      runs = DeepResearchStore.all.map(&:last)
      runs = runs.select { |r| r['id'] == id } if id
      raise Refusal, "unknown run #{id}" if id && runs.empty?

      runs.each { |r| @out.puts("#{r['id']}  #{r['state']}  #{r['slug']}  #{r['created_at']}") }
      @out.puts('no runs') if runs.empty?
      OK
    end
  end
end

exit(DeepResearch::CLI.run(ARGV)) if $PROGRAM_NAME == __FILE__
