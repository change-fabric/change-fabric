# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/ctx_store"

class CtxStoreTest < Minitest::Test
  include SkillTempHome

  # Under @home (the redirected HOME), so the store-keying guard accepts it.
  def cwd = File.join(@home, "code", "demo")

  # Records commit messages instead of shelling out to git, so writes are tested
  # without a real repo or a configured identity.
  class Recorder
    attr_reader :messages

    def initialize = @messages = []
    def call(message) = @messages << message
  end

  def setup
    super
    @committer = Recorder.new
    @clock = Time.new(2026, 6, 27, 9, 0, 0, "-04:00")
  end

  def store
    CtxStore.new(cwd: cwd, home: @home, session_id: "sess-1", device: "laptop-a",
                 committer: @committer, now: @clock)
  end

  def doc_file(klass, name)
    File.join(CtxPaths.class_dir(klass, cwd, home: @home), "#{name}.md")
  end

  def index_text
    File.read(File.join(CtxPaths.store_dir(cwd, home: @home), "INDEX.md"))
  end

  # Swaps File.rename for one that raises, so the atomic temp-then-rename write
  # can be tested without minitest/mock (absent from this bundle). The redefine
  # is wrapped to keep the warning-enabled test run quiet.
  def with_failing_rename
    original = File.method(:rename)
    swap_rename { |*| raise IOError, "boom" }
    yield
  ensure
    swap_rename(&original)
  end

  def swap_rename(&body)
    verbose = $VERBOSE
    $VERBOSE = nil
    File.singleton_class.send(:define_method, :rename, &body)
  ensure
    $VERBOSE = verbose
  end

  def test_constructor_refuses_a_cwd_outside_home
    assert_raises(CtxPaths::NotAProject) do
      CtxStore.new(cwd: "/elsewhere/scratch", home: @home, committer: @committer)
    end
  end

  def test_write_stamps_provenance_and_round_trips
    doc = store.write(name: "plan", description: "the plan: phase one", klass: "active", body: "step one")
    assert_equal "2026-06-27T09:00:00-04:00", doc.last_touched
    assert_equal "laptop-a", doc.origin_device
    assert_equal "sess-1", doc.origin_session_id

    saved = CtxStore::Doc.parse(File.read(doc_file("active", "plan")))
    assert_equal "the plan: phase one", saved.description
    assert_equal "active", saved.klass
    assert_equal "step one", saved.body
  end

  def test_truth_with_ttl_is_rejected
    error = assert_raises(CtxStore::InvalidDoc) do
      store.write(name: "msa", description: "contract", klass: "truth", ttl: "30d", body: "x")
    end
    assert_match(/truth/, error.message)
    refute File.exist?(doc_file("truth", "msa"))
  end

  def test_ephemeral_requires_a_ttl
    assert_raises(CtxStore::InvalidDoc) do
      store.write(name: "scratch", description: "tmp", klass: "ephemeral", body: "x")
    end
  end

  def test_ephemeral_ttl_computes_expiry
    doc = store.write(name: "scratch", description: "tmp", klass: "ephemeral", ttl: "14d", body: "x")
    assert_equal "2026-07-11", doc.expires
  end

  def test_unknown_class_and_bad_name_are_rejected
    assert_raises(CtxStore::InvalidDoc) { store.write(name: "x", description: "d", klass: "nope", body: "b") }
    assert_raises(CtxStore::InvalidDoc) { store.write(name: "Bad Name", description: "d", klass: "active", body: "b") }
  end

  def test_review_after_round_trips
    doc = store.write(name: "msa", description: "contract", klass: "truth", review_after: "180d", body: "x")
    assert_equal "180d", doc.review_after
    assert_equal "180d", CtxStore::Doc.parse(File.read(doc_file("truth", "msa"))).review_after
  end

  def test_bad_review_after_is_rejected
    assert_raises(CtxStore::InvalidDoc) do
      store.write(name: "msa", description: "contract", klass: "truth", review_after: "soon", body: "x")
    end
  end

  def test_index_rebuilt_after_write
    store.write(name: "plan", description: "the plan", klass: "active", body: "x")
    assert_includes index_text, "- [plan](active/plan.md) - the plan"
  end

  def test_write_commits_locally_with_device_tag
    store.write(name: "plan", description: "the plan", klass: "active", body: "x")
    assert_equal [ "ctx: capture plan [laptop-a]" ], @committer.messages
  end

  def test_partial_write_leaves_no_live_doc
    raised = false
    with_failing_rename do
      store.write(name: "plan", description: "d", klass: "active", body: "x")
    rescue IOError
      raised = true
    end
    assert raised, "expected the rename failure to surface"
    refute File.exist?(doc_file("active", "plan")), "a failed rename must leave no live doc"
  end

  def test_recall_returns_nil_for_missing
    assert_nil store.read("nope")
  end

  def test_list_filters_by_class_and_status
    store.write(name: "a", description: "da", klass: "active", body: "x")
    store.write(name: "t", description: "dt", klass: "truth", body: "x")
    store.write(name: "b", description: "db", klass: "active", status: "done", body: "x")

    assert_equal %w[a b], store.list(klass: "active").map(&:name)
    assert_equal %w[a], store.list(klass: "active", status: "active").map(&:name)
    assert_equal %w[a b t], store.list.map(&:name)
  end

  def test_delete_removes_doc_and_reindexes
    store.write(name: "a", description: "da", klass: "active", body: "x")
    assert store.delete("a")
    assert_nil store.read("a")
    refute_includes index_text, "(active/a.md)"
    assert_equal "ctx: remove a [laptop-a]", @committer.messages.last
  end

  def test_archive_drops_live_and_writes_a_digest
    store.write(name: "p", description: "the plan", klass: "active", body: "first line\nmore")
    assert store.archive("p")
    assert_nil store.read("p")

    tomb = File.join(CtxPaths.class_dir(CtxPaths::ARCHIVE, cwd, home: @home), "p.md")
    assert File.exist?(tomb), "archive tombstone should exist"
    assert_includes File.read(tomb), "the plan"
    refute_includes index_text, "(active/p.md)"
    assert_equal "ctx: archive p [laptop-a]", @committer.messages.last
  end

  def test_archive_missing_doc_returns_false
    refute store.archive("nope")
  end

  def test_entries_pair_each_doc_with_its_class_directory
    store.write(name: "t", description: "dt", klass: "truth", body: "x")
    store.write(name: "a", description: "da", klass: "active", body: "x")
    pairs = store.entries.map { |entry| [ entry.klass_dir, entry.doc.name ] }.sort
    assert_equal [ [ "active", "a" ], [ "truth", "t" ] ], pairs
  end

  def test_cli_parses_flags_and_positionals
    flags, positional = CtxStore::CLI.parse(%w[--name plan --class active some-doc --session s1])
    assert_equal({ "name" => "plan", "class" => "active", "session" => "s1" }, flags)
    assert_equal %w[some-doc], positional
  end
end
