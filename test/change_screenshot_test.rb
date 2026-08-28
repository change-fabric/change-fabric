# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../scripts/change_screenshot"

# The orchestration half of cf:screenshot: which two git states get compared,
# how the base one is stood up, and the refusal to photograph the second ref
# until the first one's server is positively gone.
#
# Every shell-out goes through ChangeScreenshot#capture, so a Probe can watch
# exactly what this class asks git and gh for without a fixture repo or a
# docker daemon. The three things worth breaking a run over are all here: a
# wrong base ref, a base side booted from the wrong directory, and a stuck
# port, each of which produces a diff that is wrong without looking wrong.
class ChangeScreenshotTest < Minitest::Test
  Boot = Struct.new(:up, :down, :health_url, :health_status, :health_timeout, :network, :target_url,
                    keyword_init: true) do
    def up? = !up.to_s.empty?
    def env_files = []
  end

  Config = Struct.new(:boot, keyword_init: true)

  # Records every shell-out and answers from a canned map keyed by a substring
  # of the joined argv, so a test states only the commands it cares about and
  # anything else comes back as a plain failure.
  class Probe < ChangeScreenshot
    attr_reader :calls, :boots

    def initialize(argv, answers: {})
      super(argv)
      @answers = answers
      @calls = []
      @boots = []
    end

    def capture(*argv)
      @calls << argv
      joined = argv.join(" ")
      key = @answers.keys.find { |needle| joined.include?(needle) }
      key ? @answers[key] : [ "", false ]
    end

    def repo_root = "/repo"
    def boot_up(_boot, chdir: repo_root) = @boots << [ :up, chdir ]
    def boot_down(_boot, chdir: repo_root) = @boots << [ :down, chdir ]
    def wait_healthy(_boot) = nil

    def git_calls = @calls.select { |argv| argv.first == "git" }
    def joined_calls = @calls.map { |argv| argv.join(" ") }
  end

  # Stands in for ChangeScreenshotCapture: records what it was asked to
  # photograph and from where.
  class ProbeCapturer
    attr_reader :sides

    def initialize = @sides = []

    def capture(session:, side:, out_dir:, base_url: nil)
      @sides << { side: side, base_url: base_url, out_dir: out_dir, session: session }
      []
    end
  end

  def probe(argv = [], answers: {}) = Probe.new(argv, answers: answers)

  def boot(up: "make dev", health_url: "http://localhost:5173/", health_status: 200)
    Boot.new(up: up, down: "make stop", health_url: health_url, health_status: health_status,
             health_timeout: 60, network: nil, target_url: "http://host.docker.internal:5173")
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  # --- ref resolution -----------------------------------------------------------

  def test_an_explicit_base_wins_and_computes_no_merge_base
    subject = probe(%w[--base v1.2.3])
    assert_equal "v1.2.3", subject.resolve_base_ref
    assert_empty subject.calls, "an explicit --base is used literally; nothing needs asking"
  end

  # Merge-base, not the branch tip: it is the only choice that guarantees the
  # diff is caused by this branch alone rather than by trunk drift that landed
  # after the branch forked.
  def test_a_pull_request_resolves_to_the_merge_base_with_its_own_base_branch
    subject = probe(%w[--pr 42], answers: { "pr view 42" => [ "release-3", true ],
                                            "merge-base HEAD origin/release-3" => [ "cafebabe", true ] })
    assert_equal "cafebabe", subject.resolve_base_ref
    assert_includes subject.joined_calls, "gh pr view 42 --json baseRefName --jq .baseRefName"
    assert_includes subject.joined_calls, "git -C /repo merge-base HEAD origin/release-3"
  end

  def test_with_no_pull_request_it_falls_back_to_the_merge_base_with_the_default_branch
    subject = probe([], answers: { "refs/remotes/origin/HEAD" => [ "origin/trunk", true ],
                                   "merge-base HEAD origin/trunk" => [ "deadbeef", true ] })
    assert_equal "deadbeef", subject.resolve_base_ref
    assert_includes subject.joined_calls, "git -C /repo merge-base HEAD origin/trunk"
  end

  def test_an_unset_origin_head_falls_back_to_asking_gh_for_the_default_branch
    subject = probe([], answers: { "repo view --json defaultBranchRef" => [ "mainline", true ],
                                   "merge-base HEAD origin/mainline" => [ "0ddba11", true ] })
    assert_equal "0ddba11", subject.resolve_base_ref
    assert_includes subject.joined_calls, "git -C /repo merge-base HEAD origin/mainline"
  end

  # Guessing "main" against a repo that uses something else produces a diff
  # that is wrong without looking wrong, so nothing here guesses.
  def test_no_resolvable_default_branch_aborts_by_name_rather_than_guessing
    subject = probe
    output = capture_stderr { assert_raises(SystemExit) { subject.resolve_base_ref } }

    assert_includes output, "cannot resolve a base ref"
    assert_includes output, "origin/HEAD is not set"
    assert_includes output, "--base"
    refute_includes subject.joined_calls.join("\n"), "merge-base"
  end

  def test_an_unresolvable_merge_base_aborts_rather_than_capturing_something_arbitrary
    subject = probe([], answers: { "refs/remotes/origin/HEAD" => [ "origin/trunk", true ] })
    output = capture_stderr { assert_raises(SystemExit) { subject.resolve_base_ref } }
    assert_includes output, "git merge-base HEAD origin/trunk failed"
  end

  # --- planning the base side -----------------------------------------------------

  def test_base_url_skips_the_worktree_and_the_boot_entirely
    subject = probe(%w[--base-url https://preview.example.org])
    side = subject.plan_base_side(Config.new(boot: boot))

    assert side.external?
    assert_equal "https://preview.example.org", side.url
    assert_nil side.commit
    assert_empty subject.calls, "an already-running base side needs no ref resolved and no worktree"

    capturer = ProbeCapturer.new
    subject.capture_base(Config.new(boot: boot), side, capturer, :session, "/out")
    assert_empty subject.boots, "nothing may be booted for an externally-provided base side"
    refute_includes subject.joined_calls.join("\n"), "worktree"
    assert_equal "https://preview.example.org", capturer.sides.first[:base_url]
  end

  # boot.up absent is the documented "assume the app is already running"
  # contract, and only one app can be already running.
  def test_an_absent_boot_up_with_no_base_url_aborts_with_a_named_reason
    subject = probe
    output = capture_stderr do
      assert_raises(SystemExit) { subject.plan_base_side(Config.new(boot: boot(up: ""))) }
    end

    assert_includes output, "assume the app is already running"
    assert_includes output, "--base-url"
  end

  # --- the worktree ------------------------------------------------------------------

  # --detach matters: a merge-base is a commit, not a branch, and a
  # non-detached add of a bare commit fails.
  def test_the_worktree_is_added_detached_at_the_resolved_commit_and_removed_after
    subject = probe([], answers: { "worktree" => [ "", true ] })
    dir = nil
    subject.in_worktree("cafebabe") { |d| dir = d }
    add = subject.git_calls.find { |argv| argv[3] == "worktree" && argv[4] == "add" }

    refute_nil dir
    assert_equal [ "git", "-C", "/repo", "worktree", "add", "--detach", dir, "cafebabe" ], add
    assert_includes subject.joined_calls, "git -C /repo worktree remove --force #{dir}"
  end

  def test_a_failed_worktree_add_aborts_rather_than_capturing_the_wrong_tree
    subject = probe
    output = capture_stderr { assert_raises(SystemExit) { subject.in_worktree("cafebabe") { |_d| flunk } } }
    assert_includes output, "git worktree add --detach"
  end

  # Booting the base side from the main working tree would boot HEAD's code and
  # produce a same-ref-twice diff presented as a real one.
  def test_the_base_side_boots_with_the_worktree_as_its_chdir_not_the_repo_root
    subject = probe([], answers: { "worktree" => [ "", true ] })
    capturer = ProbeCapturer.new
    side = ChangeScreenshot::BaseSide.new(commit: "cafebabe")
    subject.capture_base(Config.new(boot: boot), side, capturer, :session, "/out")

    worktree = subject.git_calls.find { |argv| argv[4] == "add" }[6]
    assert_equal [ [ :up, worktree ], [ :down, worktree ] ], subject.boots
    refute_equal "/repo", worktree
    assert_equal "before", capturer.sides.first[:side]
    assert_nil capturer.sides.first[:base_url], "the base side is served by the worktree's own boot"
  end

  def test_the_head_side_boots_in_the_main_working_tree
    subject = probe
    capturer = ProbeCapturer.new
    subject.capture_head(Config.new(boot: boot), capturer, :session, "/out")

    assert_equal [ [ :up, "/repo" ], [ :down, "/repo" ] ], subject.boots
    assert_equal "after", capturer.sides.first[:side]
  end

  # --- the verify-gone check -----------------------------------------------------------

  def test_the_poll_reports_gone_on_a_connection_refused
    subject = probe
    def subject.healthy?(_boot) = [ false, "curl: (7) Failed to connect" ]
    assert subject.verify_gone(boot, deadline_seconds: 0)
  end

  def test_the_poll_reports_gone_on_a_status_other_than_expect_status
    subject = probe
    # healthy? already folds the status comparison in; a 502 is a false here
    # for the same reason a refused connection is: nothing is serving.
    def subject.healthy?(_boot) = [ false, "502" ]
    assert subject.verify_gone(boot, deadline_seconds: 0)
  end

  def test_the_poll_reports_still_answering_while_the_health_url_returns_expect_status
    subject = probe
    def subject.healthy?(_boot) = [ true, "200" ]
    refute subject.verify_gone(boot, deadline_seconds: 0)
  end

  def test_a_run_with_no_health_url_has_nothing_to_verify
    subject = probe
    assert subject.verify_gone(boot(health_url: ""), deadline_seconds: 0)
  end

  # The single worst failure mode for a before/after tool is photographing the
  # same ref twice, so this must be loud and must stop the run.
  def test_a_still_answering_health_url_aborts_and_the_second_capture_never_runs
    subject = probe([], answers: { "lsof" => [ "node 4321 dev 23u IPv4 TCP *:5173 (LISTEN)", true ] })
    def subject.verify_gone(_boot, deadline_seconds: nil) = false
    second_ran = false

    output = capture_stderr do
      assert_raises(SystemExit) do
        subject.run_sides(boot: boot, base_capture: -> { [] }, head_capture: -> { second_ran = true; [] })
      end
    end

    refute second_ran, "the head ref must never be captured against a stuck base-ref server"
    assert_includes output, "http://localhost:5173/"
    assert_includes output, "Port 5173"
    assert_includes output, "node 4321"
    assert_includes output, "same ref photographed twice"
  end

  def test_the_two_sides_run_in_order_with_the_verification_between_them
    subject = probe
    def subject.verify_gone(_boot, deadline_seconds: nil) = true
    order = []
    before, after = subject.run_sides(boot: boot,
                                      base_capture: -> { order << :base; [ :b ] },
                                      head_capture: -> { order << :head; [ :a ] })

    assert_equal %i[base head], order
    assert_equal [ :b ], before
    assert_equal [ :a ], after
  end

  def test_verification_is_skipped_for_an_externally_provided_base_side
    subject = probe
    def subject.verify_gone(*) = flunk("nothing was booted, so there is nothing to verify gone")
    subject.run_sides(boot: boot, base_capture: -> { [] }, head_capture: -> { [] }, verify: false)
  end

  # --- the stale-server preflight -------------------------------------------------------

  def test_a_health_url_answering_before_anything_booted_is_a_stale_server
    subject = probe
    def subject.healthy?(_boot) = [ true, "200" ]
    output = capture_stderr do
      assert_raises(SystemExit) { subject.preflight(boot, ChangeScreenshot::BaseSide.new(commit: "abc")) }
    end

    assert_includes output, "already answering before anything was booted"
  end

  def test_the_preflight_is_silent_when_nothing_is_listening
    subject = probe
    def subject.healthy?(_boot) = [ false, "curl: (7)" ]
    assert_nil subject.preflight(boot, ChangeScreenshot::BaseSide.new(commit: "abc"))
  end
end
