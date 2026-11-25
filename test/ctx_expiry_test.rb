# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/ctx_expiry"
require_relative "#{SKILL_SCRIPTS}/triage"

# One test per row of the completion expiry truth table, plus the pin and
# revalidation guards, reversibility and mid-batch failure.
class CtxExpiryTest < Minitest::Test
  include SkillTempHome

  class Recorder
    def call(_message); end
  end

  EPIC_MD = <<~MD
    ---
    goal: test
    epic_rev: 1
    repos: [acme/api]
    plans:
      - {id: P1, repo: acme/api, dir: demo/one}
    ---
    body
  MD

  def cwd = File.join(@home, "code", "demo")

  def setup
    super
    @node_state = "done"
    @runs = 0
    FileUtils.mkdir_p(cwd)
  end

  def store
    CtxStore.new(cwd: cwd, home: @home, device: "dev", committer: Recorder.new,
                 now: Time.new(2026, 11, 25, 9, 0, 0, "-06:00"))
  end

  def pointer(name, body = "pointer")
    store.write(name: name, description: "d #{name}", klass: "active", body: body)
  end

  def stack(slug, states)
    prs = states.each_with_index.map { |state, i| { "number" => i + 1, "state" => state } }
    path = StackStore.for_dir(cwd, slug).path
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate({ "slug" => slug, "repo" => "acme/api", "prs" => prs }))
  end

  def epic_fixture
    root = File.join(@home, "plans")
    FileUtils.mkdir_p(File.join(root, "epics", "e1"))
    File.write(File.join(root, "epics", "e1", "epic.md"), EPIC_MD)
    root
  end

  def epic_link = "Epic-Node: e1 P1#Phase 1"

  def expirer(queue: [], node_state: @node_state)
    plans = epic_fixture
    runner = lambda do |_epic|
      @runs += 1
      [ EpicStatus::Node.new(id: "P1#Phase 1", repo: "acme/api", state: node_state, pr: nil) ]
    end
    factory = -> { CtxExpiry::Evidence.new(cwd: cwd, plans_root: plans, epic_runner: runner) }
    CtxExpiry::Expirer.new(cwd: cwd, evidence_factory: factory, home: @home, store: store,
                           queue: ->(verdict, _cwd) { queue << verdict.name })
  end

  def verdict(name, **opts)
    expirer(**opts).plan.find { |v| v.name == name } || flunk("no verdict for #{name}")
  end

  def live?(name) = !store.read(name).nil?

  # --- truth table ----------------------------------------------------------

  def test_stack_only_all_merged_archives
    pointer("stack-a")
    stack("a", %w[merged merged])
    assert_equal [ :archive, "stack_all_merged" ], verdict("stack-a").to_h.values_at("action", "reason").then { |a, r| [ a.to_sym, r ] }
  end

  def test_stack_only_with_an_open_pr_keeps
    pointer("stack-a")
    stack("a", %w[merged handed_off])
    assert_equal :keep, verdict("stack-a").action
  end

  def test_epic_only_done_archives
    pointer("plan-x", epic_link)
    assert_equal :archive, verdict("plan-x", node_state: "done").action
  end

  def test_epic_only_not_done_keeps
    pointer("plan-x", epic_link)
    assert_equal :keep, verdict("plan-x", node_state: "next").action
  end

  def test_both_done_archives
    pointer("stack-a", epic_link)
    stack("a", %w[merged])
    assert_equal :archive, verdict("stack-a", node_state: "done").action
  end

  def test_both_disagreeing_queues_in_either_direction
    pointer("stack-a", epic_link)
    stack("a", %w[merged])
    assert_equal [ :queue, "stack_and_epic_disagree" ], verdict("stack-a", node_state: "next").then { |v| [ v.action, v.reason ] }
    stack("a", %w[handed_off])
    assert_equal :queue, verdict("stack-a", node_state: "done").action
  end

  def test_both_open_keeps
    pointer("stack-a", epic_link)
    stack("a", %w[handed_off])
    assert_equal :keep, verdict("stack-a", node_state: "pending").action
  end

  def test_empty_pr_list_queues_never_done
    pointer("stack-a")
    stack("a", [])
    found = verdict("stack-a")
    assert_equal [ :queue, "stack_pr_list_empty" ], [ found.action, found.reason ]
  end

  def test_empty_pr_list_queues_even_when_the_epic_says_done
    pointer("stack-a", epic_link)
    stack("a", [])
    assert_equal :queue, verdict("stack-a", node_state: "done").action
  end

  def test_missing_stack_record_queues
    pointer("stack-ghost")
    assert_equal [ :queue, "stack_record_missing" ], verdict("stack-ghost").then { |v| [ v.action, v.reason ] }
  end

  def test_unreadable_stack_record_queues
    pointer("stack-a")
    path = StackStore.for_dir(cwd, "a").path
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{not json")
    assert_equal :queue, verdict("stack-a").action
  end

  def test_missing_epic_or_node_queues
    pointer("plan-x", "Epic-Node: nope P1#Phase 1")
    assert_equal [ :queue, "epic_record_missing" ], verdict("plan-x").then { |v| [ v.action, v.reason ] }
    pointer("plan-y", "Epic-Node: e1 P9#Phase 9")
    assert_equal "epic_node_missing", verdict("plan-y").reason
  end

  def test_unknown_epic_node_queues
    pointer("plan-x", epic_link)
    assert_equal :queue, verdict("plan-x", node_state: "unknown").action
  end

  def test_no_link_keeps_and_is_left_out_of_the_listing
    pointer("plan-free", "no links here")
    found = verdict("plan-free")
    assert_equal [ :keep, "no_link" ], [ found.action, found.reason ]
    assert_empty CtxExpiry.summary(expirer.plan)["pointers"]
  end

  # --- pins and revalidation ------------------------------------------------

  def pin(name)
    path = File.join(CtxPaths.class_dir("active", cwd, home: @home), "#{name}.md")
    File.write(path, File.read(path).sub("class: active\n", "class: active\npinned: true\n"))
  end

  def test_a_pinned_pointer_never_archives_or_queues
    pointer("stack-a")
    stack("a", %w[merged])
    pin("stack-a")
    subject = expirer
    assert_equal [ :keep, "pinned" ], subject.plan.first.then { |v| [ v.action, v.reason ] }
    subject.apply
    assert live?("stack-a")
    pointer("stack-b")
    pin("stack-b")
    assert_equal :keep, verdict("stack-b").action, "a pinned pointer with a missing record stays out of the queue"
  end

  def test_a_pin_added_between_plan_and_archive_skips_the_archive
    pointer("stack-a")
    stack("a", %w[merged])
    subject = expirer
    plan = subject.plan
    pin("stack-a")
    outcome = subject.apply(plan)["results"].first
    assert_equal %w[skipped pinned], outcome.values_at("outcome", "detail")
    assert live?("stack-a")
  end

  def test_evidence_that_moves_between_plan_and_archive_skips_the_archive
    pointer("stack-a")
    stack("a", %w[merged])
    subject = expirer
    plan = subject.plan
    stack("a", %w[merged handed_off])
    outcome = subject.apply(plan)["results"].first
    assert_equal %w[skipped evidence_changed], outcome.values_at("outcome", "detail")
    assert live?("stack-a")
  end

  def test_revalidation_reads_evidence_afresh_not_from_the_plan_memo
    pointer("plan-x", epic_link)
    subject = expirer
    subject.apply
    assert_operator @runs, :>=, 2, "plan and the pre-archive check each ran the epic status"
  end

  # --- apply, reversibility, idempotence ------------------------------------

  def test_twelve_finished_stacks_all_archive
    12.times do |i|
      pointer("stack-s#{i}")
      stack("s#{i}", %w[merged])
    end
    pointer("plan-free")
    applied = expirer.apply
    assert_equal 12, applied["results"].count { |row| row["outcome"] == "archived" }
    assert_equal [ "plan-free" ], store.list(klass: "active").map(&:name)
  end

  def test_unarchive_restores_the_original_byte_for_byte
    pointer("stack-a", "line one\n\nline two")
    stack("a", %w[merged])
    before = File.read(File.join(CtxPaths.class_dir("active", cwd, home: @home), "stack-a.md"))
    expirer.apply
    refute live?("stack-a")
    assert store.unarchive("stack-a")
    assert_equal before, File.read(File.join(CtxPaths.class_dir("active", cwd, home: @home), "stack-a.md"))
    refute File.exist?(File.join(CtxPaths.class_dir("archive", cwd, home: @home), "stack-a.md"))
  end

  def test_unarchive_restores_raw_bytes_that_parsing_would_normalize
    pointer("stack-a", "x")
    stack("a", %w[merged])
    path = File.join(CtxPaths.class_dir("active", cwd, home: @home), "stack-a.md")
    head = File.read(path).chomp.delete_suffix("x")
    File.write(path, "#{head}    indented\n\n\n")
    before = File.read(path)
    assert store.archive("stack-a", nil, restorable: true)
    assert store.unarchive("stack-a")
    assert_equal before, File.read(path)
  end

  def test_unarchive_refuses_a_plain_archive_and_a_taken_name
    pointer("plain")
    store.archive("plain")
    refute store.unarchive("plain"), "an archive without an embedded original cannot be restored"
    pointer("stack-a")
    store.archive("stack-a", nil, restorable: true)
    pointer("stack-a", "new")
    refute store.unarchive("stack-a"), "a live doc already holds the name"
    refute store.unarchive("missing")
  end

  def test_a_rerun_is_idempotent
    pointer("stack-a")
    stack("a", %w[merged])
    expirer.apply
    again = expirer.apply
    assert_empty again["results"]
  end

  def test_dry_run_changes_nothing
    pointer("stack-a")
    stack("a", %w[merged])
    summary = CtxExpiry.summary(expirer.plan)
    assert summary["dry_run"]
    assert live?("stack-a")
  end

  def test_an_archive_raising_mid_batch_keeps_earlier_archives_and_reports_the_rest
    %w[a b c].each do |slug|
      pointer("stack-#{slug}")
      stack(slug, %w[merged])
    end
    real = store
    calls = 0
    failing = Object.new
    failing.define_singleton_method(:method_missing) { |name, *args, **kw, &blk| real.public_send(name, *args, **kw, &blk) }
    failing.define_singleton_method(:respond_to_missing?) { |*| true }
    failing.define_singleton_method(:archive) do |name, digest = nil, **kw|
      calls += 1
      raise IOError, "disk" if calls == 2

      real.archive(name, digest, **kw)
    end
    plans = epic_fixture
    subject = CtxExpiry::Expirer.new(cwd: cwd, home: @home, store: failing, queue: ->(*) { false },
                                     evidence_factory: -> { CtxExpiry::Evidence.new(cwd: cwd, plans_root: plans) })
    outcomes = subject.apply["results"].map { |row| row["outcome"] }
    assert_equal %w[archived error not_attempted], outcomes
    assert_equal %w[stack-b stack-c], store.list(klass: "active").map(&:name)
    rerun = expirer.apply["results"].map { |row| row["outcome"] }
    assert_equal %w[archived archived], rerun
  end

  def test_store_mutators_wait_for_the_expiry_lock
    entered = Queue.new
    holder = Thread.new { store.with_lock { entered << true; sleep 0.3 } }
    entered.pop
    started = Time.now
    pointer("late")
    holder.join
    assert_operator Time.now - started, :>=, 0.2
  end

  def test_with_lock_is_reentrant_for_nested_mutators
    pointer("nested")
    one = store
    assert one.with_lock { one.archive("nested") }
  end

  def test_inbox_slug_survives_long_names_with_a_shared_prefix
    slugs = %w[one two].map { |suffix| CtxExpiry::InboxQueue.slug_for(cwd, "stack-#{'a' * 30}-#{suffix}") }
    refute_equal slugs.first, slugs.last
  end

  def test_inbox_queue_runs_from_the_expired_project
    seen = nil
    original = InboxStore.method(:humans)
    InboxStore.define_singleton_method(:humans) { seen = Dir.pwd; [] }
    begin
      CtxExpiry::InboxQueue.queue(CtxExpiry::Verdict.new("x", :queue, "r", "f"), cwd)
    ensure
      InboxStore.define_singleton_method(:humans, original)
    end
    assert_equal File.realpath(cwd), File.realpath(seen)
  end

  def test_queued_pointers_reach_the_queue_hook_only_on_apply
    pointer("stack-ghost")
    queue = []
    subject = expirer(queue: queue)
    subject.plan
    assert_empty queue
    applied = subject.apply
    assert_equal [ "stack-ghost" ], queue
    assert_equal "ctx_ambiguous", applied["queued"].first["kind"]
  end

  # --- CLI -------------------------------------------------------------------

  def run_cli(*args, expirer: nil)
    out = StringIO.new
    err = StringIO.new
    code = Triage::CLI.run(args, out: out, err: err, sources: { expirer: expirer }.compact)
    [ code, out.string, err.string ]
  end

  def test_cli_dry_run_by_default_and_apply_archives
    pointer("stack-a")
    stack("a", %w[merged])
    code, out, = run_cli("expire", "--json", expirer: expirer)
    assert_equal 0, code
    assert JSON.parse(out)["dry_run"]
    assert live?("stack-a")
    code, out, = run_cli("expire", "--apply", "--json", expirer: expirer)
    assert_equal 0, code
    assert_equal "archived", JSON.parse(out)["results"].first["outcome"]
    refute live?("stack-a")
  end

  def test_cli_rejects_a_dangling_project_flag
    code, _out, err = run_cli("expire", "--project")
    assert_equal 2, code
    assert_includes err, "usage"
  end

  def test_cli_outside_home_is_refused
    code, _out, err = run_cli("expire", "--project", "/")
    assert_equal 1, code
    assert_includes err, "triage:"
  end
end
