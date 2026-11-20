# frozen_string_literal: true

require_relative "deep_research_helper"

class DeepResearchCliTest < Minitest::Test
  include DeepResearchHelper

  def synthetic_pdf = fixture("synthetic", "report.pdf")
  def synthetic_xml = StoredExtractor.new(File.read(fixture("synthetic", "raw.xml")))

  def prompt_run(question = "A question")
    code, out, = cli("prompt", "--question", question, "--slug", "s")
    [ code, out[/Run id: (\S+)/, 1] ]
  end

  def test_prompt_writes_a_pending_run_prints_one_instruction_and_exits_6
    code, out, = cli("prompt", "--question", "A question", "--slug", "s")
    id = out[/Run id: (\S+)/, 1]
    assert_equal 6, code
    assert_match(/\ARun id: dr-/, out)
    assert_equal 1, out.lines.grep(/\APaste .*prompt\.md into ChatGPT deep research.*attach it here/).size
    dir = DeepResearchStore.run_dir("s", id)
    assert_equal "pending", DeepResearchStore.read(dir)["state"]
    assert_includes File.read(File.join(dir, "prompt.md")), "Run reference (bookkeeping only, no need to repeat it in the report): #{id}"
  end

  def test_prompt_refuses_a_sensitive_term_and_writes_nothing
    File.write(ENV["CF_SENSITIVE_TERMS_FILE"], "acmecorp\n")
    code, _out, err = cli("prompt", "--question", "How does AcmeCorp plan?", "--slug", "s")
    assert_equal 2, code
    assert_includes err, "acmecorp"
    refute File.exist?(ENV["CF_RESEARCH_ROOT"])
  end

  def test_prompt_cache_hit_prints_the_report_and_creates_nothing
    _code, id = prompt_run
    dir = DeepResearchStore.run_dir("s", id)
    DeepResearchStore.transition(dir, "ingested")
    DeepResearchStore.transition(dir, "done")
    File.write(DeepResearchStore.report_path(dir), "{}")
    before = Dir.glob(File.join(ENV["CF_RESEARCH_ROOT"], "**", "*")).sort
    code, out, = cli("prompt", "--question", "A question", "--slug", "s")
    assert_equal 0, code
    assert_equal "Cached report: #{DeepResearchStore.report_path(dir)}\n", out
    assert_equal before, Dir.glob(File.join(ENV["CF_RESEARCH_ROOT"], "**", "*")).sort
    assert_equal 6, cli("prompt", "--question", "A question", "--slug", "s", "--refresh")[0]
  end

  def test_prompt_cache_miss_past_max_age
    _code, id = prompt_run
    dir = DeepResearchStore.run_dir("s", id)
    DeepResearchStore.transition(dir, "ingested")
    DeepResearchStore.transition(dir, "done")
    File.write(DeepResearchStore.report_path(dir), "{}")
    DeepResearchStore.write(dir, DeepResearchStore.read(dir).merge("created_at" => "2020-01-01T00:00:00Z"))
    assert_equal 6, cli("prompt", "--question", "A question", "--slug", "s")[0]
  end

  def test_prompt_out_dir_copies_the_prompt
    out_dir = File.join(@tmp, "plan")
    cli("prompt", "--question", "Q", "--slug", "s", "--out-dir", out_dir)
    assert File.exist?(File.join(out_dir, "prompt.md"))
  end

  def test_ingest_moves_pending_to_ingested_to_done_and_writes_a_valid_report
    DeepResearchStore.create(record, "p")
    code, out, = cli("ingest", "--run", RUN_ID, "--pdf", synthetic_pdf, extractor: synthetic_xml)
    dir = DeepResearchStore.run_dir("synthetic", RUN_ID)
    assert_equal 0, code
    assert_equal "Report: #{DeepResearchStore.report_path(dir)}\n", out
    assert_equal "done", DeepResearchStore.read(dir)["state"]
    report = JSON.parse(File.read(DeepResearchStore.report_path(dir)))
    assert_equal [], DeepResearchSchema.validate(report)
    assert_equal %w[unverified], report["findings"].map { |f| f["status"] }.uniq - %w[contested]
    assert_equal({ "subscription" => true }, report["cost"])
    assert_equal Digest::SHA256.file(synthetic_pdf).hexdigest, report["provenance"]["pdf_sha256"]
    assert File.exist?(File.join(dir, "raw.xml")) && File.exist?(File.join(dir, "report.pdf"))
  end

  def test_ingest_takes_any_absolute_path_including_an_uploads_dir
    uploads = File.join(@tmp, ".claude", "uploads", "abc")
    FileUtils.mkdir_p(uploads)
    path = File.join(uploads, "Deep Research Report.pdf")
    FileUtils.cp(synthetic_pdf, path)
    DeepResearchStore.create(record, "p")
    assert_equal 0, cli("ingest", "--run", RUN_ID, "--pdf", path, extractor: synthetic_xml)[0]
  end

  def test_ingest_refuses_relative_paths_missing_files_and_unknown_runs
    DeepResearchStore.create(record, "p")
    assert_equal 2, cli("ingest", "--run", RUN_ID, "--pdf", "report.pdf")[0]
    assert_equal 2, cli("ingest", "--run", RUN_ID, "--pdf", File.join(@tmp, "nope.pdf"))[0]
    assert_equal 2, cli("ingest", "--run", "dr-unknown", "--pdf", synthetic_pdf)[0]
  end

  def test_ingest_refuses_a_secret_pattern_names_the_kind_and_keeps_nothing
    DeepResearchStore.create(record, "p")
    secret = "ghp_#{'a' * 30}"
    bad = StoredExtractor.new(xml("Deep research [#{RUN_ID}]", "Findings", "1. leaked #{secret}"))
    code, _out, err = cli("ingest", "--run", RUN_ID, "--pdf", synthetic_pdf, extractor: bad)
    dir = DeepResearchStore.run_dir("synthetic", RUN_ID)
    assert_equal 2, code
    assert_includes err, "provider token"
    refute_includes err, secret
    assert_equal "pending", DeepResearchStore.read(dir)["state"]
    refute File.exist?(File.join(dir, "raw.xml"))
    refute File.exist?(File.join(dir, "raw.xml.tmp"))
  end

  def test_ingest_binds_to_the_run_flag_without_the_run_id_in_the_pdf
    # A ChatGPT export holds the report only, so the id is absent: no refusal, no --force.
    DeepResearchStore.create(record("id" => "dr-00000000-0000-4000-8000-0000000000ff"), "p")
    code, out, err = cli("ingest", "--run", "dr-00000000-0000-4000-8000-0000000000ff", "--pdf", synthetic_pdf,
                         extractor: StoredExtractor.new(File.read(fixture("chatgpt", "raw.xml"))))
    assert_equal 0, code
    assert_match(/Report: /, out)
    refute_includes err, "different run"
  end

  def test_ingest_of_a_pdf_naming_another_run_warns_but_still_ingests
    DeepResearchStore.create(record("id" => "dr-00000000-0000-4000-8000-0000000000ff"), "p")
    code, _out, err = cli("ingest", "--run", "dr-00000000-0000-4000-8000-0000000000ff", "--pdf", synthetic_pdf,
                          extractor: synthetic_xml)
    assert_equal 0, code
    assert_includes err, "names a different run (#{RUN_ID})"
  end

  def test_ingest_warns_when_headings_miss_the_skeleton
    DeepResearchStore.create(record, "p")
    thin = StoredExtractor.new(xml("Summary", "Some text.", "Findings", "1. A claim."))
    code, _out, err = cli("ingest", "--run", RUN_ID, "--pdf", synthetic_pdf, extractor: thin)
    assert_equal 0, code
    assert_includes err, "headings do not match the skeleton (missing: sources, unverified, contested)"
  end

  def test_real_chatgpt_fixture_ingests_to_the_expected_report
    DeepResearchStore.create(record, "p")
    pdf = fixture("chatgpt", "report.pdf")
    assert_equal 0, cli("ingest", "--run", RUN_ID, "--pdf", pdf,
                        extractor: StoredExtractor.new(File.read(fixture("chatgpt", "raw.xml"))))[0]
    report = JSON.parse(File.read(DeepResearchStore.report_path(DeepResearchStore.run_dir("synthetic", RUN_ID))))
    expected = JSON.parse(File.read(fixture("chatgpt", "report.json")))
    assert_equal [], DeepResearchSchema.validate(report)
    assert_equal expected["findings"], report["findings"]
    assert_equal expected["sources"], report["sources"]
    assert_equal expected["citations"], report["citations"]
    assert_equal "none", report["provenance"]["link_annotations"]
  end

  def test_ingesting_the_same_pdf_twice_is_a_no_op
    DeepResearchStore.create(record, "p")
    cli("ingest", "--run", RUN_ID, "--pdf", synthetic_pdf, extractor: synthetic_xml)
    DeepResearchStore.create(record("id" => "dr-00000000-0000-4000-8000-0000000000aa"), "p")
    before = Dir.glob(File.join(ENV["CF_RESEARCH_ROOT"], "**", "*")).size
    code, out, = cli("ingest", "--run", "dr-00000000-0000-4000-8000-0000000000aa", "--pdf", synthetic_pdf)
    assert_equal 0, code
    assert_match(/\AAlready ingested: .*report\.json\n\z/, out)
    assert_equal before, Dir.glob(File.join(ENV["CF_RESEARCH_ROOT"], "**", "*")).size
  end

  def test_ingest_out_dir_copies_the_report
    DeepResearchStore.create(record, "p")
    out_dir = File.join(@tmp, "plan")
    cli("ingest", "--run", RUN_ID, "--pdf", synthetic_pdf, "--out-dir", out_dir, extractor: synthetic_xml)
    assert File.exist?(File.join(out_dir, "report.json"))
  end

  def test_ingest_without_pdftohtml_names_p2
    DeepResearchStore.create(record, "p")
    saved = ENV["PATH"]
    ENV["PATH"] = @tmp
    code, _out, err = cli("ingest", "--run", RUN_ID, "--pdf", synthetic_pdf)
    ENV["PATH"] = saved
    assert_equal 2, code
    assert_includes err, "P2"
  end

  def test_status_lists_runs
    DeepResearchStore.create(record, "p")
    code, out, = cli("status")
    assert_equal 0, code
    assert_includes out, "#{RUN_ID}  pending  synthetic"
    assert_equal 2, cli("status", "--run", "dr-nope")[0]
  end

  def test_unknown_command_is_a_usage_error
    assert_equal 2, cli("frobnicate")[0]
  end
end
