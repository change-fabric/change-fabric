# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "yaml"
require_relative "git_fixture"
require_relative "../scripts/change_prod_redeploy"
require_relative "../scripts/change_prod_schema"

class ChangeProdRedeployTest < Minitest::Test
  R = ChangeProdRedeploy
  CONFIG = File.expand_path("fixtures/prod/valid.yml", __dir__)
  OLD = "a" * 40
  NEW = "b" * 40
  OLDER = "c" * 40
  HISTORY = [ { "sha" => NEW, "state" => "success" }, { "sha" => NEW, "state" => "failure" },
              { "sha" => OLD, "state" => "success" }, { "sha" => OLDER, "state" => "success" } ].freeze
  TAGS = { OLD => %w[v1.2.0 v1.10.0 nightly], NEW => %w[v1.3.0] }.freeze

  def config
    cfg = YAML.safe_load(File.read(CONFIG))
    cfg["change_config"]["operations"]["redeploy_previous"] = Marshal.load(Marshal.dump(R::TEMPLATE))
    cfg
  end

  def tags_at = ->(sha) { TAGS.fetch(sha, []) }

  def test_template_passes_the_schema_floors
    assert_empty ChangeProdSchema.errors(config)
  end

  def test_predecessor_is_the_newest_earlier_success_at_another_commit
    assert_equal OLD, R.predecessor(HISTORY)
  end

  def test_predecessor_refuses_without_history
    assert_raises(R::Refused) { R.predecessor([]) }
    assert_raises(R::Refused) { R.predecessor([ { "sha" => NEW, "state" => "failure" } ]) }
    assert_raises(R::Refused) { R.predecessor([ { "sha" => NEW, "state" => "success" }, { "sha" => NEW, "state" => "success" } ]) }
  end

  def test_params_pick_the_highest_release_tag_at_the_predecessor
    assert_equal({ "previous_release" => "v1.10.0", "previous_sha" => OLD }, R.params_for(HISTORY, tags_at: tags_at))
  end

  def test_params_refuse_when_no_release_tag_points_at_the_predecessor
    assert_raises(R::Refused) { R.params_for(HISTORY, tags_at: ->(_) { %w[nightly] }) }
  end

  def test_check_refuses_a_moved_tag_or_a_wrong_predecessor
    params = { "previous_release" => "v1.10.0", "previous_sha" => OLD }
    assert R.check(params, deployments: HISTORY, resolve_tag: ->(_) { OLD })
    assert_raises(R::Refused) { R.check(params, deployments: HISTORY, resolve_tag: ->(_) { NEW }) }
    assert_raises(R::Refused) { R.check(params.merge("previous_sha" => OLDER), deployments: HISTORY, resolve_tag: ->(_) { OLDER }) }
  end

  def test_offer_builds_a_digested_envelope_and_writes_only_the_request_ref
    Dir.mktmpdir do |dir|
      GitFixture.git_init(dir, "-b", "main")
      store = ChangeProdStore.new(dir)
      envelope = R.offer(config: config, profile: "production", version: NEW, requested_by: "agent:triage",
                         deployments: HISTORY, tags_at: tags_at, store: store, push: false)
      assert_equal "redeploy_previous", envelope["op"]
      assert_equal "production", envelope["environment"]
      assert_equal OLD, envelope["params"]["previous_sha"]
      assert_equal envelope, store.read("requests", envelope["request_id"])
      refute store.exists?("approvals", envelope["request_id"])
    end
  end

  def test_offer_refuses_when_the_op_is_not_declared_in_the_built_in_shape
    cfg = config
    cfg["change_config"]["operations"]["redeploy_previous"].delete("online_safe")
    assert_raises(R::Refused) { R.offer(config: cfg, profile: "production", version: NEW, requested_by: "agent:t", deployments: HISTORY, tags_at: tags_at) }
    cfg["change_config"]["operations"].delete("redeploy_previous")
    refute R.declared?(cfg)
  end

  def test_cli_template_and_offer
    out = StringIO.new
    assert_equal 0, R.run([ "template" ], stdout: out)
    assert_includes out.string, "redeploy_previous"
    Dir.mktmpdir do |dir|
      GitFixture.git_init(dir, "-b", "main")
      path = File.join(dir, "cfg.yml")
      File.write(path, YAML.dump(config))
      out = StringIO.new
      code = R.run([ "offer", "--config", path, "--profile", "production", "--repo", dir, "--version", NEW, "--incident", "inc-1", "--no-push" ],
                   stdout: out, stderr: StringIO.new, env: { "CLAUDE_SESSION_ID" => "s9" },
                   history: ->(_repo, env) { env == "production" ? HISTORY : [] }, tags: ->(_repo, sha) { TAGS.fetch(sha, []) })
      assert_equal 0, code
      assert_includes out.string, "redeploys v1.10.0"
      assert_includes out.string, "for incident inc-1"
      assert_includes out.string, "A human must now approve it"
    end
  end

  def fake_gh(statuses_by_id, fail_on: nil)
    lambda do |_repo, path|
      raise R::Refused, "cannot read #{path}" if fail_on && path.include?(fail_on)

      if path.include?("/statuses")
        statuses_by_id.fetch(path[%r{deployments/(\d+)/}, 1].to_i)
      else
        statuses_by_id.keys.map { |id| { "id" => id, "sha" => id == 1 ? NEW : OLD } }
      end
    end
  end

  def test_history_keeps_a_success_behind_an_inactive_status
    gh = fake_gh({ 1 => [ { "state" => "success" } ], 2 => [ { "state" => "inactive" }, { "state" => "success" } ] })
    history = R.gh_history(".", "production", gh: gh)
    assert_equal %w[success success], history.map { |d| d["state"] }
    assert_equal OLD, R.predecessor(history)
  end

  def test_history_refuses_when_a_status_lookup_fails
    gh = fake_gh({ 1 => [ { "state" => "success" } ], 2 => [ { "state" => "success" } ] }, fail_on: "deployments/2/statuses")
    assert_raises(R::Refused) { R.gh_history(".", "production", gh: gh) }
  end

  def test_history_never_counts_a_deployment_that_only_failed
    gh = fake_gh({ 1 => [ { "state" => "success" } ], 2 => [ { "state" => "inactive" }, { "state" => "failure" } ] })
    assert_raises(R::Refused) { R.predecessor(R.gh_history(".", "production", gh: gh)) }
  end

  def test_offer_defaults_the_version_to_origin_main_when_origin_head_is_absent
    Dir.mktmpdir do |dir|
      GitFixture.git_init(dir, "-b", "main")
      GitFixture.git(dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "base")
      sha = GitFixture.git(dir, "rev-parse", "HEAD").strip
      GitFixture.git(dir, "update-ref", "refs/remotes/origin/main", sha)
      path = File.join(dir, "cfg.yml")
      File.write(path, YAML.dump(config))
      out = StringIO.new
      code = R.run([ "offer", "--config", path, "--profile", "production", "--repo", dir, "--no-push" ],
                   stdout: out, stderr: StringIO.new, history: ->(*) { HISTORY }, tags: ->(_repo, s) { TAGS.fetch(s, []) })
      assert_equal 0, code
      id = out.string[/request_id: (\S+)/, 1]
      assert_equal sha, ChangeProdStore.new(dir).read("requests", id)["version"]
    end
  end

  def test_history_pages_past_retries_of_the_current_sha
    retries = (1..R::PAGE_SIZE).map { |id| { "id" => id, "sha" => NEW } }
    older = [ { "id" => 100, "sha" => OLD } ]
    pages = []
    gh = lambda do |_repo, path|
      next [ { "state" => "success" } ] if path.include?("/statuses")

      pages << path[/&page=(\d+)/, 1].to_i
      pages.last == 1 ? retries : older
    end
    history = R.gh_history(".", "production", gh: gh)
    assert_equal [ 1, 2 ], pages
    assert_equal OLD, R.predecessor(history)
  end

  def test_history_stops_paging_at_the_cap
    full = (1..R::PAGE_SIZE).map { |id| { "id" => id, "sha" => NEW } }
    pages = 0
    gh = lambda do |_repo, path|
      next [ { "state" => "success" } ] if path.include?("/statuses")

      pages += 1
      full
    end
    assert_raises(R::Refused) { R.predecessor(R.gh_history(".", "production", gh: gh)) }
    assert_equal R::MAX_PAGES, pages
  end

  def test_cli_refuses_an_unknown_verb_and_missing_history
    assert_equal 2, R.run([ "nope" ], stderr: StringIO.new)
    err = StringIO.new
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cfg.yml")
      File.write(path, YAML.dump(config))
      code = R.run([ "offer", "--config", path, "--profile", "production", "--repo", dir, "--version", NEW, "--no-push" ],
                   stdout: StringIO.new, stderr: err, history: ->(*) { [] }, tags: ->(*) { [] })
      assert_equal 1, code
      assert_includes err.string, "refused"
    end
  end
end
