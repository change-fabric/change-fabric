# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/deep_research"

# Shared setup for the deep_research tests: an isolated research root and
# sensitive-terms file, plus builders for runs and hand-made pdftohtml xml.
module DeepResearchHelper
  FIXTURES = File.expand_path("fixtures/deep_research", __dir__)
  RUN_ID = "dr-00000000-0000-4000-8000-000000000001"

  def setup
    @tmp = Dir.mktmpdir
    @saved = ENV.to_h.slice("CF_RESEARCH_ROOT", "CF_SENSITIVE_TERMS_FILE")
    ENV["CF_RESEARCH_ROOT"] = File.join(@tmp, "research")
    ENV["CF_SENSITIVE_TERMS_FILE"] = File.join(@tmp, "terms.txt")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
    %w[CF_RESEARCH_ROOT CF_SENSITIVE_TERMS_FILE].each { |k| ENV[k] = @saved[k] }
  end

  def cli(*argv, extractor: nil)
    out = StringIO.new
    err = StringIO.new
    code = DeepResearch::CLI.run(argv, out: out, err: err, extractor: extractor)
    [ code, out.string, err.string ]
  end

  def record(overrides = {})
    { "id" => RUN_ID, "slug" => "synthetic", "state" => "pending", "backend" => "manual", "model" => "chatgpt-web",
      "question" => "Synthetic skeleton report", "prompt_sha256" => "0" * 64, "cache_key" => "key",
      "created_at" => "2026-11-20T00:00:00Z", "response_id" => nil, "pdf_sha256" => nil,
      "script_version" => "1" }.merge(overrides)
  end

  def fixture(*parts) = File.join(FIXTURES, *parts)

  # Hand-made pdftohtml xml: each entry is text or [text, href].
  def xml(*entries, page: 1)
    body = entries.map do |text, href|
      inner = href ? %(<a href="#{href}">#{text}</a>) : text
      %(<text top="1" left="1" width="1" height="1" font="0">#{inner}</text>)
    end
    %(<pdf2xml><page number="#{page}" position="absolute" top="0" left="0" height="1" width="1">#{body.join("\n")}</page></pdf2xml>)
  end

  # Serves a stored raw.xml in place of the pdftohtml binary.
  class StoredExtractor
    def initialize(xml) = @xml = xml
    def extract(_pdf) = @xml
  end
end
