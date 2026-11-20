# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require_relative "git_fixture"
require_relative "../scripts/incident_store"

class IncidentStoreTest < Minitest::Test
  T0 = "2026-03-02T10:00:00Z"
  T1 = "2026-03-02T10:05:00Z"
  T2 = "2026-03-02T11:00:00Z"

  def setup
    @tmp = Dir.mktmpdir
    @root = File.join(@tmp, "incidents")
    @prev_known = ENV.delete("CF_KNOWN_REPO_ROOTS")
  end

  def teardown
    ENV["CF_KNOWN_REPO_ROOTS"] = @prev_known if @prev_known
    FileUtils.remove_entry(@tmp)
  end

  def store(repo: "acme-web", **opts) = IncidentStore.new(repo: repo, root: @root, **opts)

  def make(slug = "bad-fixture", **opts) = store.create(slug: slug, at: T0, **opts)

  def inc(id, repo: "acme-web") = JSON.parse(File.read(File.join(@root, repo, id, "incident.json")))

  def timeline(id) = File.read(File.join(@root, "acme-web", id, "timeline.md")).lines

  def assert_invalid(match = nil, &block)
    err = assert_raises(IncidentStore::Invalid, &block)
    assert_match(match, err.message) if match
    err
  end

  # Drives an incident to `fixing` with everything verified needs recorded.
  def ready_to_verify(id)
    s = store
    s.set(id, { "status" => "fixing", "probe" => "curl /health", "probe_expected" => "200",
                "hotfix.fix_version" => "v1.2.1" }, at: T1)
    s.set(id, { "serving_version" => "v1.2.1", "serving_source" => "deploy_api" }, at: T1)
    s.set(id, { "probe_result" => "pass", "regression.login" => "pass", "regression.checkout" => "pass" }, at: T1)
    s
  end

  def reach_reported(id)
    s = ready_to_verify(id)
    s.set(id, { "status" => "verified" }, at: T2)
    s.set(id, { "status" => "reported" }, at: T2)
    s
  end

  def record_hotfix(s, id)
    s.set(id, { "hotfix.pr_url" => "https://example.test/pr/1", "hotfix.merge_sha" => "abc1234" }, at: T2)
  end

  def write_rca(id, mtime: Time.now + 60)
    file = File.join(@root, "acme-web", id, "rca.md")
    File.write(file, "# RCA\n")
    File.utime(mtime, mtime, file)
  end

  # --- create, layout, ids ---------------------------------------------------

  def test_create_lays_out_the_record_and_prints_a_dated_id
    id = make("Bad Fixture", client: "the-client", severity: "sev1")
    assert_equal "2026-03-02-bad-fixture", id
    dir = File.join(@root, "acme-web", id)
    %w[incident.json timeline.md ops.json].each { |name| assert File.file?(File.join(dir, name)), name }
    assert File.directory?(File.join(dir, "evidence"))
    record = inc(id)
    assert_equal "cf.incident-1", record["schema"]
    assert_equal %w[open sev1 the-client acme-web], record.values_at("status", "severity", "client", "repo")
    assert_equal [], JSON.parse(File.read(File.join(dir, "ops.json")))
  end

  def test_create_refuses_an_existing_id
    make
    assert_invalid(/already exists/) { make }
  end

  def test_ids_are_repo_scoped
    make
    other = IncidentStore.new(repo: "acme/api", root: @root).create(slug: "bad-fixture", at: T0)
    assert_equal "2026-03-02-bad-fixture", other
    assert File.directory?(File.join(@root, "acme-api", other))
    assert_invalid(/no incident/) { IncidentStore.new(repo: "acme/api", root: @root).resolve("nope") }
  end

  def test_create_validates_severity_and_timestamp
    assert_invalid(/severity/) { store.create(slug: "x", at: T0, severity: "sev9") }
    assert_invalid(/ISO 8601/) { store.create(slug: "x", at: "yesterday") }
  end

  def test_cf_incidents_dir_override_sets_the_default_root
    ENV["CF_INCIDENTS_DIR"] = @root
    assert_equal @root, IncidentStore.new(repo: "acme-web").root
    id = IncidentStore.new(repo: "acme-web").create(slug: "env", at: T0)
    assert File.directory?(File.join(@root, "acme-web", id))
  ensure
    ENV.delete("CF_INCIDENTS_DIR")
  end

  # --- resume ----------------------------------------------------------------

  def test_resume_accepts_a_unique_prefix_and_names_a_missing_id
    id = make("one")
    assert_equal id, store.resolve("2026-03-02-o")
    assert_equal id, store.resolve(id)
    assert_invalid(/no incident "2026-04"/) { store.resolve("2026-04") }
  end

  def test_resume_refuses_an_ambiguous_prefix
    make("one")
    make("other")
    err = assert_invalid(/ambiguous/) { store.resolve("2026-03-02") }
    assert_match(/2026-03-02-one, 2026-03-02-other/, err.message)
  end

  # --- the non-git refusal ---------------------------------------------------

  def test_refuses_a_root_inside_a_git_work_tree
    repo = File.join(@tmp, "checkout")
    FileUtils.mkdir_p(repo)
    GitFixture.git_init(repo)
    assert_invalid(/inside a git work tree/) { IncidentStore.new(repo: "acme-web", root: File.join(repo, "inc")) }
  end

  def test_refuses_a_nested_repo_root_that_does_not_exist_yet
    repo = File.join(@tmp, "checkout")
    FileUtils.mkdir_p(repo)
    GitFixture.git_init(repo)
    deep = File.join(repo, "a", "b", "incidents")
    refute File.exist?(File.join(repo, "a"))
    assert_invalid(/inside a git work tree/) { IncidentStore.new(repo: "acme-web", root: deep).create(slug: "x", at: T0) }
    refute File.exist?(File.join(repo, "a"))
  end

  def test_refuses_a_root_under_the_repo_checkout_path_and_known_roots
    shared = File.join(@tmp, "plain")
    FileUtils.mkdir_p(shared)
    assert_invalid(/under the repo root/) do
      IncidentStore.new(repo: "acme-web", root: File.join(shared, "x", "inc"), repo_path: shared)
    end
    ENV["CF_KNOWN_REPO_ROOTS"] = "/nowhere/else:#{shared}"
    assert_invalid(/under the repo root/) { IncidentStore.new(repo: "acme-web", root: File.join(shared, "x", "inc")) }
  end

  def test_known_root_check_follows_symlinks
    real = File.join(@tmp, "real")
    FileUtils.mkdir_p(real)
    link = File.join(@tmp, "link")
    File.symlink(real, link)
    assert_invalid(/under the repo root/) do
      IncidentStore.new(repo: "acme-web", root: File.join(link, "missing", "inc"), known_roots: real)
    end
  end

  def test_a_plain_directory_is_accepted
    assert_equal @root, store.root
  end

  # --- timeline --------------------------------------------------------------

  def test_append_keeps_order_and_one_line_per_event
    id = make
    store.append(id, at: T1, actor: "agent", text: "first\nsecond")
    store.append(id, at: T2, actor: "patrick", text: "third")
    lines = timeline(id)
    assert_match(/incident .* opened/, lines[0])
    assert_equal "- 2026-03-02T10:05:00Z agent: first second\n", lines[1]
    assert_equal "- 2026-03-02T11:00:00Z patrick: third\n", lines[2]
    assert_equal 3, lines.size
  end

  # --- ops -------------------------------------------------------------------

  def test_record_op_drafts_with_a_runbook_command_file
    id = make
    file = File.join(@tmp, "rollback.sh")
    op_id = store.record_op(id, kind: "rollback", via: "runbook", at: T1, commands_file: file)
    assert_equal "op-1", op_id
    op = JSON.parse(File.read(File.join(@root, "acme-web", id, "ops.json"))).first
    assert_equal %w[op-1 rollback runbook drafted], op.values_at("op_id", "kind", "via", "status")
    assert_equal file, op["commands_file"]
    assert_nil op["approved_by"]
    assert_match(/op-1 drafted/, timeline(id).last)
  end

  def test_record_op_validates_kind_via_and_pairing
    id = make
    assert_invalid(/kind/) { store.record_op(id, kind: "nuke", via: "runbook", at: T1, commands_file: "f") }
    assert_invalid(/via/) { store.record_op(id, kind: "rollback", via: "ssh", at: T1) }
    assert_invalid(/request-id/) { store.record_op(id, kind: "redeploy", via: "prod_runner", at: T1) }
    assert_invalid(/commands-file/) { store.record_op(id, kind: "rollback", via: "runbook", at: T1) }
    assert_equal "op-1", store.record_op(id, kind: "redeploy", via: "prod_runner", at: T1, request_id: "req-9")
    assert_equal "op-2", store.record_op(id, kind: "tag", via: "runbook", at: T1, commands_file: "t.sh")
  end

  def op(id) = JSON.parse(File.read(File.join(@root, "acme-web", id, "ops.json"))).first

  def draft(id) = store.record_op(id, kind: "rollback", via: "runbook", at: T1, commands_file: "r.sh")

  def test_op_allowed_transitions
    id = make
    op_id = draft(id)
    store.update_op(id, op_id: op_id, status: "approved", approved_by: "patrick", at: T1)
    assert_equal "patrick", op(id)["approved_by"]
    store.update_op(id, op_id: op_id, status: "running", at: T1)
    store.update_op(id, op_id: op_id, status: "succeeded", result: "serving v1.2.0", evidence: "evidence/curl.txt", at: T2)
    assert_equal %w[succeeded], [ op(id)["status"] ]
    assert_equal "serving v1.2.0", op(id)["result"]
    assert_equal [ "evidence/curl.txt" ], op(id)["evidence"]
    assert_match(/op-1 succeeded/, timeline(id).last)
  end

  def test_op_running_can_fail_and_a_drafted_op_can_be_abandoned
    id = make
    a = draft(id)
    store.update_op(id, op_id: a, status: "failed", result: "abandoned", at: T1)
    b = draft(id)
    store.update_op(id, op_id: b, status: "approved", approved_by: "patrick", at: T1)
    store.update_op(id, op_id: b, status: "running", at: T1)
    store.update_op(id, op_id: b, status: "failed", result: "health check failed", at: T2)
    ops = JSON.parse(File.read(File.join(@root, "acme-web", id, "ops.json")))
    assert_equal %w[failed failed], ops.map { |o| o["status"] }
  end

  def test_op_refused_transitions
    id = make
    op_id = draft(id)
    [ %w[running], %w[succeeded], %w[drafted] ].flatten.each do |status|
      assert_invalid(/cannot go to #{status}/) do
        store.update_op(id, op_id: op_id, status: status, result: "x", at: T1)
      end
    end
    store.update_op(id, op_id: op_id, status: "approved", approved_by: "patrick", at: T1)
    assert_invalid(/cannot go to failed/) { store.update_op(id, op_id: op_id, status: "failed", result: "x", at: T1) }
    store.update_op(id, op_id: op_id, status: "running", at: T1)
    store.update_op(id, op_id: op_id, status: "succeeded", result: "ok", at: T1)
    assert_invalid(/cannot go to running/) { store.update_op(id, op_id: op_id, status: "running", at: T1) }
    assert_invalid(/no op "op-9"/) { store.update_op(id, op_id: "op-9", status: "approved", approved_by: "p", at: T1) }
  end

  def test_op_approved_needs_approver_and_terminal_states_need_a_result
    id = make
    op_id = draft(id)
    assert_invalid(/--approved-by/) { store.update_op(id, op_id: op_id, status: "approved", at: T1) }
    assert_equal "drafted", op(id)["status"]
    store.update_op(id, op_id: op_id, status: "approved", approved_by: "patrick", at: T1)
    store.update_op(id, op_id: op_id, status: "running", at: T1)
    assert_invalid(/needs --result/) { store.update_op(id, op_id: op_id, status: "succeeded", at: T1) }
    assert_invalid(/needs --result/) { store.update_op(id, op_id: op_id, status: "failed", result: " ", at: T1) }
  end

  # --- set and the incident status table -------------------------------------

  ALLOWED = { "open" => %w[mitigated fixing], "mitigated" => %w[fixing], "fixing" => %w[verified unverified],
              "unverified" => %w[fixing verified], "verified" => %w[reported], "reported" => %w[closed] }.freeze

  def test_every_allowed_transition_is_in_the_table_and_the_rest_are_refused
    flow = IncidentStore::STATUS_FLOW
    ALLOWED.each { |from, tos| assert_equal tos, flow[from], from }
    statuses = flow.keys
    statuses.each do |from|
      (statuses - ALLOWED.fetch(from, []) - [ from ]).each do |to|
        refute_includes flow[from], to, "#{from} -> #{to} must be refused"
      end
    end
  end

  def test_set_walks_the_lifecycle_and_refuses_jumps
    id = make
    s = store
    assert_invalid(/open cannot go to verified/) { s.set(id, { "status" => "verified" }, at: T1) }
    assert_invalid(/open cannot go to reported/) { s.set(id, { "status" => "reported" }, at: T1) }
    s.set(id, { "status" => "mitigated" }, at: T1)
    assert_equal T1, inc(id)["mitigated_at"]
    assert_invalid(/mitigated cannot go to unverified/) { s.set(id, { "status" => "unverified" }, at: T1) }
    s.set(id, { "status" => "fixing" }, at: T1)
    assert_invalid(/fixing cannot go to mitigated/) { s.set(id, { "status" => "mitigated" }, at: T1) }
    assert_invalid(/fixing cannot go to reported/) { s.set(id, { "status" => "reported" }, at: T1) }
    assert_match(/status mitigated -> fixing/, timeline(id).last)
  end

  def test_set_cannot_close_and_rejects_unknown_keys_and_bad_values
    id = reach_reported_id
    assert_invalid(/close command/) { store.set(id, { "status" => "closed" }, at: T2) }
    assert_invalid(/unknown key "colour"/) { store.set(id, { "colour" => "red" }, at: T2) }
    assert_invalid(/severity/) { store.set(id, { "severity" => "sev0" }, at: T2) }
    assert_invalid(/serving_source/) { store.set(id, { "serving_source" => "tag" }, at: T2) }
    assert_invalid(/regression x/) { store.set(id, { "regression.x" => "maybe" }, at: T2) }
    assert_invalid(/probe_result must be/) { store.set(id, { "probe_result" => "great" }, at: T2) }
    assert_invalid(/unknown hotfix field/) { store.set(id, { "hotfix.nope" => "1" }, at: T2) }
  end

  def reach_reported_id
    id = make
    reach_reported(id)
    id
  end

  def test_a_refused_set_changes_nothing
    id = make
    before = File.read(File.join(@root, "acme-web", id, "incident.json"))
    assert_invalid { store.set(id, { "probe" => "curl /x", "status" => "verified" }, at: T1) }
    assert_equal before, File.read(File.join(@root, "acme-web", id, "incident.json"))
  end

  def test_probe_result_needs_a_recorded_probe
    id = make
    assert_invalid(/record the probe/) { store.set(id, { "probe_result" => "pass" }, at: T1) }
  end

  # --- verified rule ---------------------------------------------------------

  def fixing(id) = store.set(id, { "status" => "fixing" }, at: T1)

  def test_verified_refused_without_probe_source_or_p0_rows
    id = make
    fixing(id)
    err = assert_invalid(/verified refused/) { store.set(id, { "status" => "verified" }, at: T2) }
    assert_match(/no triage probe/, err.message)
    assert_match(/fix_version not recorded/, err.message)
    assert_match(/deploy_api or version_endpoint/, err.message)
    assert_match(/no P0 regression rows/, err.message)
    assert_match(/probe has not passed/, err.message)
  end

  def test_verified_refused_on_a_tag_only_serving_source
    id = make
    s = ready_to_verify(id)
    assert_invalid(/serving_source must be/) { s.set(id, { "serving_source" => "git_tag" }, at: T2) }
    record = inc(id)
    record["hotfix"]["serving_source"] = nil
    File.write(File.join(@root, "acme-web", id, "incident.json"), JSON.generate(record))
    assert_invalid(/deploy_api or version_endpoint/) { s.set(id, { "status" => "verified" }, at: T2) }
  end

  def test_verified_refused_when_a_p0_row_fails
    id = make
    s = ready_to_verify(id)
    s.set(id, { "regression.checkout" => "fail" }, at: T2)
    assert_invalid(/not passing: checkout/) { s.set(id, { "status" => "verified" }, at: T2) }
  end

  def test_verified_refused_when_serving_version_is_not_the_fix
    id = make
    s = ready_to_verify(id)
    s.set(id, { "serving_version" => "v1.2.0" }, at: T2)
    assert_invalid(/does not equal fix_version/) { s.set(id, { "status" => "verified" }, at: T2) }
  end

  def test_verified_refused_when_the_probe_passed_on_the_rolled_back_version
    id = make
    s = store
    s.set(id, { "status" => "fixing", "probe" => "curl /health", "hotfix.fix_version" => "v1.2.1",
                "serving_version" => "v1.2.0", "serving_source" => "deploy_api" }, at: T1)
    s.set(id, { "probe_result" => "pass", "regression.login" => "pass" }, at: T1)
    s.set(id, { "serving_version" => "v1.2.1" }, at: T2)
    assert_invalid(/probe passed while serving "v1.2.0"/) { s.set(id, { "status" => "verified" }, at: T2) }
    s.set(id, { "probe_result" => "pass" }, at: T2)
    s.set(id, { "status" => "verified" }, at: T2)
    assert_equal "verified", inc(id)["status"]
  end

  def test_verified_succeeds_with_everything_and_stamps_fixed_at
    id = make
    ready_to_verify(id)
    store.set(id, { "status" => "verified" }, at: T2)
    record = inc(id)
    assert_equal "verified", record["status"]
    assert_equal T2, record["fixed_at"]
    assert_equal "v1.2.1", record["hotfix"]["serving_version"]
  end

  def test_version_endpoint_is_an_accepted_source
    id = make
    s = ready_to_verify(id)
    s.set(id, { "serving_source" => "version_endpoint" }, at: T1)
    s.set(id, { "status" => "verified" }, at: T2)
    assert_equal "verified", inc(id)["status"]
  end

  def test_auth_failure_sets_unverified_and_unverified_can_recover
    id = make
    s = store
    s.set(id, { "status" => "fixing", "probe" => "curl /health" }, at: T1)
    s.set(id, { "probe_result" => "auth_failure" }, at: T1)
    assert_equal "unverified", inc(id)["status"]
    assert_match(/status fixing -> unverified/, timeline(id).last)
    s.set(id, { "status" => "fixing" }, at: T2)
    s.set(id, { "probe_result" => "inconclusive" }, at: T2)
    assert_equal "unverified", inc(id)["status"]
    assert_equal "inconclusive", inc(id)["probe_result"]["result"]
  end

  # --- follow-ups and close --------------------------------------------------

  def test_follow_up_states_and_updates
    id = make
    s = store
    assert_equal 1, s.follow_up_add(id, title: "alert on fixtures", at: T1)
    assert_equal 2, s.follow_up_add(id, title: "lint", url: "https://example.test/i/2", at: T1)
    assert_equal %w[drafted tracked], inc(id)["follow_ups"].map { |f| f["state"] }
    s.follow_up_update(id, n: 1, url: "https://example.test/i/1", at: T2)
    assert_equal "tracked", inc(id)["follow_ups"][0]["state"]
    assert_invalid(/no follow-up/) { s.follow_up_update(id, n: 5, url: "u", at: T2) }
    assert_invalid(/--url or --accepted-untracked/) { s.follow_up_update(id, n: 1, at: T2) }
    assert_invalid(/needs --by/) { s.follow_up_update(id, n: 1, accepted_untracked: true, at: T2) }
    assert_invalid(/title/) { s.follow_up_add(id, title: " ", at: T1) }
  end

  def test_close_refuses_before_reported
    id = make
    err = assert_invalid(/not reported/) { store.close(id, at: T2) }
    assert_match(/rca.md does not exist/, err.message)
    ready_to_verify(id)
    store.set(id, { "status" => "verified" }, at: T2)
    assert_invalid(/status is verified, not reported/) { store.close(id, at: T2) }
  end

  def test_close_refuses_a_drafted_follow_up_and_accepts_untracked
    id = make
    s = reach_reported(id)
    record_hotfix(s, id)
    s.set(id, { "hotfix.serving_version" => "v1.2.1" }, at: T2)
    write_rca(id)
    s.follow_up_add(id, title: "prevent", at: T2)
    assert_invalid(/follow-ups not tracked or accepted: 1/) { s.close(id, at: T2) }
    s.follow_up_update(id, n: 1, accepted_untracked: true, by: "patrick", at: T2)
    assert_equal "patrick", inc(id)["follow_ups"][0]["accepted_by"]
    s.close(id, at: T2)
    assert_equal %w[closed], [ inc(id)["status"] ]
    assert_equal T2, inc(id)["closed_at"]
  end

  def test_close_with_a_tracked_follow_up
    id = make
    s = reach_reported(id)
    record_hotfix(s, id)
    write_rca(id)
    s.follow_up_add(id, title: "prevent", url: "https://example.test/i/3", at: T2)
    s.close(id, at: T2)
    assert_equal "closed", inc(id)["status"]
    assert_match(/incident closed/, timeline(id).last)
  end

  def test_close_refused_until_the_rca_is_updated_after_verify
    id = make
    s = ready_to_verify(id)
    write_rca(id, mtime: Time.now - 3600)
    s.set(id, { "status" => "verified" }, at: T2)
    s.set(id, { "status" => "reported" }, at: T2)
    record_hotfix(s, id)
    assert_invalid(/rca.md was not updated after the verified transition/) { s.close(id, at: T2) }
    write_rca(id)
    s.close(id, at: T2)
    assert_equal "closed", inc(id)["status"]
  end

  def test_close_refused_without_the_hotfix_record
    id = make
    s = reach_reported(id)
    write_rca(id)
    assert_invalid(/hotfix fields not recorded: pr_url, merge_sha/) { s.close(id, at: T2) }
  end

  def test_nothing_changes_after_close
    id = make
    s = reach_reported(id)
    record_hotfix(s, id)
    write_rca(id)
    s.close(id, at: T2)
    assert_invalid(/closed cannot go to/) { s.set(id, { "status" => "fixing" }, at: T2) }
  end

  # --- the command line ------------------------------------------------------

  def cli(*args)
    out = StringIO.new
    err = StringIO.new
    code = IncidentStoreCli.new([ *args, "--repo", "acme-web" ], out: out, err: err).run
    [ code, out.string.strip, err.string.strip ]
  end

  def with_root
    ENV["CF_INCIDENTS_DIR"] = @root
    yield
  ensure
    ENV.delete("CF_INCIDENTS_DIR")
  end

  def test_cli_round_trip
    with_root do
      code, id, = cli("create", "--slug", "boom", "--at", T0)
      assert_equal 0, code
      assert_equal "2026-03-02-boom", id
      assert_equal 0, cli("append", "--id", id, "--at", T1, "--actor", "agent", "--text", "saw it").first
      assert_equal 0, cli("set", "--id", id, "--at", T1, "--status", "fixing", "--probe", "curl /h",
                          "--regression", "login=pass", "--regression", "pay=fail", "hotfix.pr_url=https://x.test/1").first
      record = inc(id)
      assert_equal "fixing", record["status"]
      assert_equal({ "login" => "pass", "pay" => "fail" }, record["regressions"])
      assert_equal "https://x.test/1", record["hotfix"]["pr_url"]
      assert_equal 0, cli("follow-up", "add", "--id", id, "--title", "t", "--at", T1).first
      assert_equal 0, cli("follow-up", "update", "--id", id, "--n", "1", "--accepted-untracked", "--by", "patrick", "--at", T1).first
      code, op_id, = cli("record-op", "--id", id, "--kind", "rollback", "--via", "runbook", "--at", T1, "--commands-file", "r.sh")
      assert_equal [ 0, "op-1" ], [ code, op_id ]
      assert_equal 0, cli("update-op", "--id", id, "--op-id", op_id, "--status", "approved", "--approved-by", "patrick", "--at", T1).first
      assert_equal File.join(@root, "acme-web", id), cli("path", "--id", id)[1]
    end
  end

  def test_cli_reports_errors_with_a_nonzero_exit
    with_root do
      code, _, err = cli("create", "--slug", "x", "--at", "nope")
      assert_equal 1, code
      assert_match(/incident_store: --at must be an ISO 8601/, err)
      assert_equal 2, cli("frobnicate").first
      id = cli("create", "--slug", "y", "--at", T0)[1]
      assert_equal 1, cli("set", "--id", id, "--at", T1, "--status", "verified").first
    end
  end

  def test_cli_refuses_a_git_root_through_the_environment
    repo = File.join(@tmp, "checkout")
    FileUtils.mkdir_p(repo)
    GitFixture.git_init(repo)
    ENV["CF_INCIDENTS_DIR"] = File.join(repo, "incidents")
    code, _, err = cli("create", "--slug", "x", "--at", T0)
    assert_equal 1, code
    assert_match(/git work tree/, err)
  ensure
    ENV.delete("CF_INCIDENTS_DIR")
  end

  def test_the_script_runs_as_a_process
    out, status = Open3.capture2e({ "CF_INCIDENTS_DIR" => @root }, RbConfig.ruby,
                                  File.expand_path("../scripts/incident_store.rb", __dir__),
                                  "create", "--repo", "acme-web", "--slug", "proc", "--at", T0)
    assert status.success?, out
    assert_equal "2026-03-02-proc", out.strip
  end
end
