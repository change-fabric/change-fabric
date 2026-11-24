# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "git_fixture"
require_relative "../scripts/change_prod_request"
require_relative "../scripts/change_prod_gate"

class ChangeProdRequestTest < Minitest::Test
  Request = ChangeProdRequest
  FIXTURE = File.expand_path("fixtures/prod/runner.yml", __dir__)

  def setup
    @dir = Dir.mktmpdir
    GitFixture.git_init(@dir, "-b", "main")
    GitFixture.git(@dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "base")
    @sha = GitFixture.git(@dir, "rev-parse", "HEAD").strip
    GitFixture.git(@dir, "update-ref", "refs/remotes/origin/main", @sha)
    @store = ChangeProdStore.new(@dir)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_create_prints_the_class_notice
    code, out, = create
    assert_equal 0, code
    assert_includes out, "is class contracts_and_auth"
    assert_includes out, "Needs passkey and TOTP"
  end

  def create(*extra, out: StringIO.new, err: StringIO.new)
    argv = [ "create", "--op", "rotate_tenant_key", "--param", "tenant_id=t_101", "--profile", "staging", "--config", FIXTURE,
             "--repo", @dir, "--no-push" ] + extra
    [ Request.run(argv, stdout: out, stderr: err, env: { "CLAUDE_SESSION_ID" => "s1" }), out.string, err.string ]
  end

  def request_id(out) = out[/request_id: (\S+)/, 1]

  def test_version_defaults_to_the_remote_default_branch_not_main
    GitFixture.git(@dir, "update-ref", "refs/remotes/origin/trunk", @sha)
    GitFixture.git(@dir, "update-ref", "-d", "refs/remotes/origin/main")
    GitFixture.git(@dir, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
    assert_equal @sha, ChangeProdRequest.base_sha(@dir)
    GitFixture.git(@dir, "symbolic-ref", "--delete", "refs/remotes/origin/HEAD")
    assert_raises(ChangeProdEnvelope::Invalid) { ChangeProdRequest.base_sha(@dir) }
  end

  def test_create_writes_the_request_ref_and_prints_the_digest
    code, out, = create
    assert_equal 0, code
    envelope = @store.read("requests", request_id(out))
    assert_equal "agent:s1", envelope["requested_by"]
    assert_equal @sha, envelope["version"]
    assert_includes out, envelope["digest"]
    assert_includes out, "A human must now approve"
  end

  def test_create_refuses_undeclared_ops_params_and_profiles
    _, _, err = create("--op", "drop_database")
    assert_match(/not declared/, err)
    code, _, err = create("--param", "tenant_id=t_1; rm -rf /")
    assert_equal 1, code
    assert_match(/does not match its pattern/, err)
    code, = create("--profile", "qa")
    assert_equal 1, code
  end

  def test_create_refuses_without_a_resolvable_version
    GitFixture.git(@dir, "update-ref", "-d", "refs/remotes/origin/main")
    code, _, err = create
    assert_equal 1, code
    assert_match(/cannot resolve the default branch/, err)
  end

  def test_dispatch_refuses_until_an_approval_for_the_digest_exists
    _, out, = create
    id = request_id(out)
    calls = []
    runner = ->(workflow, rid, _repo) { calls << [ workflow, rid ] || true }
    err = StringIO.new
    argv = [ "dispatch", id, "--config", FIXTURE, "--repo", @dir, "--no-push" ]
    assert_equal 1, Request.run(argv.dup, stdout: StringIO.new, stderr: err, runner: runner)
    assert_match(/not approved yet/, err.string)
    assert_empty calls

    @store.create("approvals", id, { "protocol" => "cf.prod.approval/2", "request_id" => id, "digest" => "sha256:#{'0' * 64}", "proof" => {} }, push: false)
    err = StringIO.new
    assert_equal 1, Request.run(argv.dup, stdout: StringIO.new, stderr: err, runner: runner)
    assert_match(/does not name this request digest/, err.string)
    assert_empty calls
  end

  def test_dispatch_starts_the_declared_workflow_once_approved
    _, out, = create
    id = request_id(out)
    digest = @store.read("requests", id)["digest"]
    @store.create("approvals", id, { "protocol" => "cf.prod.approval/2", "request_id" => id, "digest" => digest, "proof" => {} }, push: false)
    calls = []
    runner = ->(workflow, rid, repo) { calls << [ workflow, rid, repo ] }
    assert_equal 0, Request.run([ "dispatch", id, "--config", FIXTURE, "--repo", @dir, "--no-push" ], stdout: StringIO.new, runner: runner)
    assert_equal [ [ "cf-prod.yml", id, @dir ] ], calls
  end

  def test_dispatch_reports_a_failed_gh_call_and_a_changed_config
    _, out, = create
    id = request_id(out)
    digest = @store.read("requests", id)["digest"]
    @store.create("approvals", id, { "protocol" => "cf.prod.approval/2", "request_id" => id, "digest" => digest, "proof" => {} }, push: false)
    err = StringIO.new
    assert_equal 1, Request.run([ "dispatch", id, "--config", FIXTURE, "--repo", @dir, "--no-push" ], stdout: StringIO.new, stderr: err, runner: ->(*) { false })
    assert_match(/dispatch failed/, err.string)
    changed = File.join(@dir, "changed.yml")
    config = YAML.safe_load_file(FIXTURE)
    config["change_config"]["operations"]["rotate_tenant_key"]["timeout_s"] = 1
    File.write(changed, YAML.dump(config))
    err = StringIO.new
    assert_equal 1, Request.run([ "dispatch", id, "--config", changed, "--repo", @dir, "--no-push" ], stdout: StringIO.new, stderr: err, runner: ->(*) { true })
    assert_match(/config_digest does not match/, err.string)
  end

  def test_the_real_dispatch_runs_inside_the_selected_checkout
    assert_raises(SystemCallError) { Request.gh_dispatch("cf-prod.yml", SecureRandom.uuid, File.join(@dir, "no-such-checkout")) }
  end

  def test_usage_and_bad_flags
    assert_equal 2, Request.run([ "nope" ], stderr: StringIO.new)
    assert_equal 1, Request.run([ "create", "--bogus" ], stderr: StringIO.new)
  end

  def dispatch(id, waiver: nil, runner: ->(*) { true })
    out = StringIO.new
    err = StringIO.new
    argv = [ "dispatch", id, "--config", FIXTURE, "--repo", @dir, "--no-push" ]
    opts = { stdout: out, stderr: err, runner: runner }
    opts[:waiver] = waiver if waiver
    [ Request.run(argv, **opts), out.string, err.string ]
  end

  def test_dispatch_with_no_approval_runs_under_an_active_autopilot_and_logs_the_waiver
    _, out, = create
    id = request_id(out)
    calls = []
    waiver = ->(repo, detail) { calls << [ repo, detail ]; "a" * 64 }
    code, stdout, = dispatch(id, waiver: waiver)
    assert_equal 0, code
    assert_match(/dispatched cf-prod.yml for #{id} under autopilot aaaaaaaaaaaa/, stdout)
    assert_equal [ [ @dir, "dispatch rotate_tenant_key #{id}" ] ], calls
  end

  def test_dispatch_with_no_approval_and_no_autopilot_still_refuses
    _, out, = create
    code, _, err = dispatch(request_id(out), waiver: ->(*) { nil })
    assert_equal 1, code
    assert_match(/not approved yet: no approval ref, and no active autopilot lists prod/, err)
  end

  def test_the_default_waiver_fails_closed_without_an_autopilot
    home = Dir.mktmpdir
    previous = ENV["HOME"]
    ENV["HOME"] = home
    _, out, = create
    code, _, err = dispatch(request_id(out))
    assert_equal 1, code
    assert_match(/not approved yet/, err)
  ensure
    ENV["HOME"] = previous
    FileUtils.remove_entry(home) if home
  end

  def test_an_existing_approval_ref_is_never_overridden_by_an_autopilot
    _, out, = create
    id = request_id(out)
    @store.create("approvals", id, { "protocol" => "cf.prod.approval/2", "request_id" => id, "digest" => "sha256:#{'0' * 64}", "proof" => {} }, push: false)
    asked = []
    code, _, err = dispatch(id, waiver: ->(*) { asked << true; "a" * 64 })
    assert_equal 1, code
    assert_match(/does not name this request digest/, err)
    assert_empty asked
  end
end
