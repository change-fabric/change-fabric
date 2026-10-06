# frozen_string_literal: true

require_relative "test_helpers"

# Fixtures are trimmed from PR #237's real review history (Codex reviews on
# 567bce1, e24f742, a58def4, e068235, with the viewer's thread replies in
# between): real logins, paths, short shas, thread titles and reply first
# sentences. The viewer is always the placeholder "viewer-login".
class ThreadHistoryTest < Minitest::Test
  VIEWER = "viewer-login"
  CODEX = "chatgpt-codex-connector"
  COLOR = "scripts/color_check.rb"
  P1_BADGE = "**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>  "
  P2_BADGE = "**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>  "

  ROUND1 = [
    [ "PRRT_pb_25", nil, 161, "#{P1_BADGE}Resolve theme overrides against inherited root tokens**",
      "Fixed in 4a0c408. Theme blocks now inherit the base :root declarations." ],
    [ "PRRT_pb_3B", 280, 254, "#{P1_BADGE}Composite alpha hex colors before contrast**",
      "Fixed in a55862c. Eight-digit #RRGGBBAA is now composited over the theme background." ],
    [ "PRRT_pb_3K", nil, 27, "#{P2_BADGE}Match text-role names at token boundaries**",
      "Fixed in 9345400. TEXT_NAME now matches only whole hyphen-separated token segments." ],
    [ "PRRT_pb_3O", nil, 135, "#{P2_BADGE}Scan non-token rules in the selected token file**",
      "Fixed in e24f742. In the token file only custom-property declarations are exempt now." ]
  ].freeze

  ROUND2 = [
    [ "PRRT_pcUuW", 28, "#{P2_BADGE}Prefer exact background-role token names**" ],
    [ "PRRT_pcUuh", 26, "#{P2_BADGE}Recognize four-digit hex colors**" ],
    [ "PRRT_pcUun", 141, "#{P2_BADGE}Exempt multiline token declarations from stray findings**" ],
    [ "PRRT_pcUuv", 228, "#{P2_BADGE}Stop variable cycles before recursing**" ]
  ].freeze

  def setup
    @db = 4_194_623_494
  end

  # -- fixture helpers, in the GraphQL `data` shape --------------------------

  # When each fixture commit was reviewed, in PR order, so a comment's
  # createdAt and a review's submittedAt follow the commit they were made on.
  REVIEWED_AT = { "567bce1" => "2026-10-01", "bc6a1ef" => "2026-10-01", "e24f742" => "2026-10-02",
                  "c921dc8" => "2026-10-02", "a58def4" => "2026-10-03", "e068235" => "2026-10-04" }.freeze

  def at(oid) = "#{REVIEWED_AT.fetch(oid, '2026-10-01')}T00:00:00Z"

  def review(login, oid, comments: [], body: "", id: "PRR_#{login}_#{oid}", db: @db += 1)
    { "id" => id, "databaseId" => db, "author" => { "login" => login }, "commit" => { "oid" => oid },
      "submittedAt" => at(oid), "body" => body,
      "comments" => { "nodes" => comments.map { |b| { "body" => b, "path" => COLOR } } } }
  end

  def thread(id:, path:, resolved:, line:, comments:, outdated: false, original_line: line)
    { "id" => id, "isResolved" => resolved, "isOutdated" => outdated, "path" => path,
      "line" => line, "originalLine" => original_line, "comments" => { "nodes" => comments } }
  end

  def comment(login, body, review_id:, oid:, db: @db += 1)
    { "id" => "PRRC_#{db}", "databaseId" => db, "author" => { "login" => login }, "body" => body,
      "createdAt" => at(oid),
      "pullRequestReview" => { "id" => review_id, "commit" => { "oid" => oid } } }
  end

  def data(reviews:, threads:, head:, review_next: false, thread_next: false)
    { "viewer" => { "login" => VIEWER },
      "repository" => { "pullRequest" => {
        "number" => 237, "headRefOid" => head,
        "reviews" => { "pageInfo" => { "hasNextPage" => review_next }, "nodes" => reviews },
        "reviewThreads" => { "pageInfo" => { "hasNextPage" => thread_next }, "nodes" => threads }
      } } }
  end

  def history(**kwargs)
    ThreadHistory.new(data(**kwargs)).to_h
  end

  def codex_review_id(oid)
    "PRR_#{CODEX}_#{oid}"
  end

  # The four 567bce1 threads; resolved with their real `Fixed in` replies
  # when fixed is true, unresolved and unanswered otherwise.
  def round1_threads(fixed:, path: COLOR, reply: nil)
    ROUND1.map do |id, line, original, body, fix_reply|
      opener = comment(CODEX, "#{body}\n\nDetail.", review_id: codex_review_id("567bce1"), oid: "567bce1")
      replies = fixed ? [ comment(VIEWER, reply || fix_reply, review_id: "PRR_v_#{id}", oid: "e24f742") ] : []
      thread(id: id, path: path, resolved: fixed, outdated: line.nil?, line: line,
             original_line: original, comments: [ opener, *replies ])
    end
  end

  def round2_threads(path: COLOR)
    ROUND2.map do |id, line, body|
      opener = comment(CODEX, "#{body}\n\nDetail.", review_id: codex_review_id("e24f742"), oid: "e24f742")
      thread(id: id, path: path, resolved: false, line: line, comments: [ opener ])
    end
  end

  def round2_reviews
    viewer_replies = ROUND1.map { |id, *| review(VIEWER, "e24f742", id: "PRR_v_#{id}", comments: [ "Fixed in x." ]) }
    [ review(CODEX, "567bce1", comments: Array.new(4, "x")), *viewer_replies,
      review(CODEX, "e24f742", comments: Array.new(4, "x")) ]
  end

  def round2(prior_path: COLOR, reply: nil)
    history(reviews: round2_reviews, head: "e24f742",
            threads: round1_threads(fixed: true, path: prior_path, reply: reply) + round2_threads)
  end

  # -- 1. round one -----------------------------------------------------------

  def test_round_one_slice_does_not_fire
    h = history(reviews: [ review(CODEX, "567bce1", comments: Array.new(4, "x")) ],
                threads: round1_threads(fixed: false), head: "567bce1")
    assert_equal({ CODEX => 1 }, h["rounds"])
    refute h["recurrence"]["fired"]
    assert_equal [], h["recurrence"]["paths"]
    assert_equal [], h["recurrence"]["reviewers"]
    assert_equal 4, h["threads"].size
    assert_empty h["priorThreads"]
  end

  # -- 2. round two -----------------------------------------------------------

  def test_round_two_slice_fires_on_the_same_path
    h = round2
    assert_equal({ CODEX => 2 }, h["rounds"])
    assert h["recurrence"]["fired"]
    assert_equal ThreadHistory::ROUND_THRESHOLD, h["recurrence"]["threshold"]
    assert_equal [ COLOR ], h["recurrence"]["paths"]
    assert_equal [ CODEX ], h["recurrence"]["reviewers"]
    assert_equal ROUND2.map(&:first), h["threads"].map { |t| t["threadId"] }
    assert_equal %w[4a0c408 a55862c 9345400 e24f742], h["priorThreads"].map { |p| p["fixSha"] }
    assert_equal [ CODEX ], h["priorThreads"].map { |p| p["reviewer"] }.uniq
  end

  # -- 2b. recurrence is the same reviewer returning ----------------------------

  # One fixed thread and one open thread, varied along every identity field
  # recurrence must match on: path, reviewer, reviewed commit and order.
  # Only the same reviewer, back on a later commit to the same path, fires.
  def recurrence_case(prior_by: CODEX, prior_oid: "567bce1", prior_path: COLOR, open_by: CODEX, open_oid: "e24f742")
    prior = thread(id: "PRRT_prior", path: prior_path, resolved: true, line: 10,
                   comments: [ comment(prior_by, "#{P2_BADGE}Prior**", review_id: "PRR_#{prior_by}_#{prior_oid}", oid: prior_oid),
                               comment(VIEWER, "Fixed in abc1234. Done.", review_id: "PRR_v", oid: prior_oid) ])
    open = thread(id: "PRRT_open", path: COLOR, resolved: false, line: 20,
                  comments: [ comment(open_by, "#{P2_BADGE}Open**", review_id: "PRR_#{open_by}_#{open_oid}", oid: open_oid) ])
    reviews = %w[567bce1 e24f742].flat_map { |oid| [ review(CODEX, oid), review("other-bot", oid) ] }
    history(reviews: reviews, threads: [ prior, open ], head: "e24f742")["recurrence"]
  end

  def test_recurrence_requires_the_same_reviewer_on_a_later_commit
    variants = {
      "same reviewer, later commit, same path" => [ {}, true ],
      "different reviewer fixed the prior thread" => [ { prior_by: "other-bot" }, false ],
      "open thread is another reviewer's" => [ { open_by: "other-bot" }, false ],
      "prior fix on a different path" => [ { prior_path: "scripts/other.rb" }, false ],
      "same reviewed commit as the prior thread" => [ { open_oid: "567bce1" }, false ],
      "open thread predates the prior thread" => [ { prior_oid: "e24f742", open_oid: "567bce1" }, false ]
    }
    variants.each do |name, (kwargs, fires)|
      r = recurrence_case(**kwargs)
      assert_equal fires, r["fired"], name
      assert_equal(fires ? [ "PRRT_open" ] : [], r["threadIds"], name)
    end
  end

  def test_recurrence_lists_only_the_returning_reviewers_threads
    other = thread(id: "PRRT_other", path: COLOR, resolved: false, line: 30,
                   comments: [ comment("other-bot", "x", review_id: "PRR_other-bot_e24f742", oid: "e24f742") ])
    reviews = round2_reviews + [ review("other-bot", "567bce1"), review("other-bot", "e24f742") ]
    h = history(reviews: reviews, head: "e24f742", threads: round1_threads(fixed: true) + round2_threads + [ other ])
    assert_equal ROUND2.map(&:first), h["recurrence"]["threadIds"]
    assert_equal [ CODEX ], h["recurrence"]["reviewers"]
  end

  # -- 3. different path ------------------------------------------------------

  def test_prior_fixes_on_a_different_path_do_not_fire
    h = round2(prior_path: "scripts/other.rb")
    assert_equal 4, h["priorThreads"].size
    refute h["recurrence"]["fired"]
  end

  # -- 4. dismissal reply only ------------------------------------------------

  def test_dismissal_reply_is_not_a_prior_thread
    h = round2(reply: "Leaving this as is on purpose. Standalone .svg files are mostly logos.")
    assert_empty h["priorThreads"]
    refute h["recurrence"]["fired"]
  end

  # -- 5. viewer reviews do not count as rounds -------------------------------

  def test_viewer_reviews_are_excluded_from_rounds
    reviews = %w[e24f742 a58def4 e068235].map { |oid| review(VIEWER, oid) } + [ review(CODEX, "567bce1") ]
    h = history(reviews: reviews, threads: [], head: "e068235")
    assert_equal({ CODEX => 1 }, h["rounds"])
  end

  def test_reviews_with_no_author_are_skipped
    h = history(reviews: [ review(CODEX, "567bce1").merge("author" => nil) ], threads: [], head: "567bce1")
    assert_equal({}, h["rounds"])
  end

  # -- 6. path-generic, #230 ----------------------------------------------------

  # Trimmed from PR #230 (fetched with QUERY): a Codex P1 on bc6a1ef in
  # scripts/skill_inject.rb, resolved by the viewer, then a Codex P2 on
  # c921dc8 in the same file. #230's real reply opened "Acted on, ..." and
  # predates the `Fixed in <sha>` reply contract, so as fetched it is not a
  # prior thread; the second case gives it the contract reply to show the
  # rule fires on any path, not only scripts/color_check.rb.
  def pr230(reply)
    path = "scripts/skill_inject.rb"
    first = thread(id: "PRRT_ji_se", path: path, resolved: true, outdated: true, line: nil, original_line: 89,
                   comments: [ comment(CODEX, "#{P1_BADGE}Do not skip publishable linked worktrees**",
                                       review_id: codex_review_id("bc6a1ef"), oid: "bc6a1ef"),
                               comment(VIEWER, reply, review_id: "PRR_v_230", oid: "c921dc8") ])
    second = thread(id: "PRRT_jjefE", path: path, resolved: false, line: 105,
                    comments: [ comment(CODEX, "#{P2_BADGE}Mark disposable worktrees explicitly**",
                                        review_id: codex_review_id("c921dc8"), oid: "c921dc8") ])
    reviews = [ review(CODEX, "bc6a1ef"), review(VIEWER, "c921dc8", id: "PRR_v_230"), review(CODEX, "c921dc8") ]
    history(reviews: reviews, threads: [ first, second ], head: "c921dc8")
  end

  def test_pr230_as_fetched_does_not_fire
    h = pr230("Acted on, with one correction to the premise: git does distinguish the two cases.")
    assert_equal({ CODEX => 2 }, h["rounds"])
    assert_empty h["priorThreads"]
    refute h["recurrence"]["fired"]
  end

  def test_pr230_with_a_fixed_reply_fires_on_its_own_path
    h = pr230("Fixed in c921dc8. Linked worktrees are told apart from detached checkouts.")
    assert h["recurrence"]["fired"]
    assert_equal [ "scripts/skill_inject.rb" ], h["recurrence"]["paths"]
    assert_equal "c921dc8", h["priorThreads"].first["fixSha"]
  end

  # -- 7. deferred --------------------------------------------------------------

  def deferred_thread(*extra)
    opener = comment(CODEX, "#{P1_BADGE}Keep base declarations separate from light overrides**",
                     review_id: codex_review_id("e068235"), oid: "e068235")
    reply = comment(VIEWER, "Deferred to plan pr-237-css-declaration-parsing. Root cause: regex scanning.",
                    review_id: "PRR_v_def", oid: "e068235")
    thread(id: "PRRT_pdXZT", path: COLOR, resolved: false, line: 167, comments: [ opener, reply, *extra ])
  end

  def test_deferred_thread_is_listed_with_its_slug_and_left_out_of_threads
    h = history(reviews: [], threads: [ deferred_thread ], head: "e068235")
    assert_empty h["threads"]
    assert_equal [ { "threadId" => "PRRT_pdXZT", "path" => COLOR,
                     "title" => "Keep base declarations separate from light overrides",
                     "slug" => "pr-237-css-declaration-parsing" } ],
                 h["deferred"].map { |d| d.slice("threadId", "path", "title", "slug") }
  end

  def test_reviewer_comment_after_the_deferral_reopens_the_thread
    later = comment(CODEX, "This still reproduces on the new head.", review_id: codex_review_id("f00ba47"), oid: "f00ba47")
    h = history(reviews: [], threads: [ deferred_thread(later) ], head: "f00ba47")
    assert_empty h["deferred"]
    assert_equal [ "PRRT_pdXZT" ], h["threads"].map { |t| t["threadId"] }
  end

  # A deferral is read by author, never by position: only the thread's own
  # reviewer commenting after the latest viewer deferral reopens it.
  def test_deferral_holds_until_the_threads_reviewer_comments_after_it
    after = ->(login, body, oid = "f00ba47") { comment(login, body, review_id: "PRR_#{login}_#{oid}", oid: oid) }
    redefer = "Deferred to plan pr-237-redesign. Root cause: still regex scanning."
    variants = {
      "deferral last" => [ [], "pr-237-css-declaration-parsing" ],
      "viewer plan link after" => [ [ after.call(VIEWER, "Plan: https://example.invalid/plan") ],
                                    "pr-237-css-declaration-parsing" ],
      "bot status after" => [ [ after.call("github-actions", "CI passed.") ], "pr-237-css-declaration-parsing" ],
      "other human after" => [ [ after.call("someone", "+1") ], "pr-237-css-declaration-parsing" ],
      "reviewer after" => [ [ after.call(CODEX, "Still reproduces.") ], nil ],
      "reviewer then viewer note" => [ [ after.call(CODEX, "Still reproduces."), after.call(VIEWER, "Looking.") ], nil ],
      "reviewer then re-deferral" => [ [ after.call(CODEX, "Still reproduces."), after.call(VIEWER, redefer) ],
                                       "pr-237-redesign" ],
      "re-deferral then reviewer" => [ [ after.call(VIEWER, redefer), after.call(CODEX, "No.", "f00ba48") ], nil ]
    }
    variants.each do |name, (extra, slug)|
      h = history(reviews: [], threads: [ deferred_thread(*extra) ], head: "f00ba47")
      if slug
        assert_empty h["threads"], name
        assert_equal [ slug ], h["deferred"].map { |d| d["slug"] }, name
      else
        assert_empty h["deferred"], name
        assert_equal [ "PRRT_pdXZT" ], h["threads"].map { |t| t["threadId"] }, name
      end
    end
  end

  def test_a_deferral_phrase_from_someone_else_is_not_a_deferral
    t = thread(id: "PRRT_x", path: COLOR, resolved: false, line: 1,
               comments: [ comment(CODEX, "x", review_id: "r", oid: "o"),
                           comment("someone", "Deferred to plan fake-slug. Cause.", review_id: "s", oid: "o") ])
    h = history(reviews: [], threads: [ t ], head: "o")
    assert_empty h["deferred"]
    assert_equal [ "PRRT_x" ], h["threads"].map { |e| e["threadId"] }
  end

  # -- 8-10. thread fields ------------------------------------------------------

  def test_title_strips_codex_badge_markup_and_bold
    titles = history(reviews: [], threads: round1_threads(fixed: false), head: "567bce1")["threads"].map { |t| t["title"] }
    assert_equal [ "Resolve theme overrides against inherited root tokens", "Composite alpha hex colors before contrast",
                   "Match text-role names at token boundaries", "Scan non-token rules in the selected token file" ], titles
  end

  def test_title_uses_first_non_empty_line_and_caps_length
    body = "\n\n  #{'word ' * 40}\nsecond line"
    t = thread(id: "PRRT_x", path: COLOR, resolved: false, line: 1,
               comments: [ comment(CODEX, body, review_id: "r", oid: "o") ])
    title = history(reviews: [], threads: [ t ], head: "o")["threads"].first["title"]
    assert_equal ThreadHistory::TITLE_CAP, title.length
    assert title.start_with?("word word")
  end

  def test_outdated_thread_falls_back_to_original_line
    t = thread(id: "PRRT_pb_3B", path: COLOR, resolved: false, outdated: true, line: nil, original_line: 280,
               comments: [ comment(CODEX, "x", review_id: "r", oid: "567bce1") ])
    entry = history(reviews: [], threads: [ t ], head: "e068235")["threads"].first
    assert_equal 280, entry["line"]
    assert entry["isOutdated"]
  end

  def test_thread_fields_come_from_the_opening_comment
    opener = comment(CODEX, "#{P2_BADGE}Parse a variable as the second color-mix stop**",
                     review_id: codex_review_id("e068235"), oid: "e068235", db: 4_195_176_618)
    reply = comment(VIEWER, "Looking.", review_id: "PRR_v", oid: "e068235", db: 4_195_200_000)
    t = thread(id: "PRRT_pdXZm", path: COLOR, resolved: false, line: 26, comments: [ opener, reply ])
    entry = history(reviews: [], threads: [ t ], head: "e068235")["threads"].first
    assert_equal 4_195_176_618, entry["commentId"]
    assert_equal CODEX, entry["reviewer"]
    assert_equal "e068235", entry["reviewedCommit"]
    assert_equal [ CODEX, VIEWER ], entry["comments"].map { |c| c["author"] }
  end

  # The REST replies endpoint accepts only a top-level review comment, so
  # commentId is the opener's id whatever follows it in the thread.
  def test_comment_id_is_always_the_opener
    opener = -> { comment(CODEX, "x", review_id: "r", oid: "o", db: 100) }
    variants = {
      "opener only" => [ opener.call ],
      "viewer reply" => [ opener.call, comment(VIEWER, "Looking.", review_id: "v", oid: "o", db: 101) ],
      "reviewer follow-up" => [ opener.call, comment(CODEX, "Still wrong.", review_id: "r2", oid: "p", db: 102) ],
      "reopened deferral" => [ opener.call, comment(VIEWER, "Deferred to plan fix-x. Cause.", review_id: "v", oid: "o", db: 103),
                               comment(CODEX, "Not fixed.", review_id: "r3", oid: "q", db: 104) ],
      "other user last" => [ opener.call, comment(VIEWER, "Hm.", review_id: "v", oid: "o", db: 105),
                             comment("someone", "+1", review_id: "s", oid: "o", db: 106) ]
    }
    variants.each do |name, cs|
      t = thread(id: "PRRT_#{name.tr(' ', '_')}", path: COLOR, resolved: false, line: 1, comments: cs)
      entry = history(reviews: [], threads: [ t ], head: "o")["threads"].first
      assert_equal 100, entry["commentId"], name
    end
  end

  def test_reviewed_commit_is_nil_when_the_review_is_absent
    opener = comment(CODEX, "x", review_id: "r", oid: "o").merge("pullRequestReview" => nil)
    t = thread(id: "PRRT_x", path: COLOR, resolved: false, line: 1, comments: [ opener ])
    assert_nil history(reviews: [], threads: [ t ], head: "o")["threads"].first["reviewedCommit"]
  end

  # -- 11. reviewRound ----------------------------------------------------------

  def code_review_round(head:, resolved: true, outdated: false, header: "**🟠 P2 - Missing row**")
    reviews = [ review(VIEWER, "aaaaaaa", id: "PRR_cr", db: 3_310_000_001, comments: [ header ]) ]
    t = thread(id: "PRRT_cr", path: COLOR, resolved: resolved, outdated: outdated, line: 10,
               comments: [ comment(VIEWER, header, review_id: "PRR_cr", oid: "aaaaaaa") ])
    history(reviews: reviews, threads: [ t ], head: head)["reviewRound"]
  end

  def test_second_round_when_head_moved_and_prior_thread_resolved
    r = code_review_round(head: "bbbbbbb")
    assert_equal [ { "id" => "PRR_cr", "databaseId" => 3_310_000_001, "reviewer" => VIEWER, "commit" => "aaaaaaa",
                     "submittedAt" => at("aaaaaaa"), "titles" => [ "Missing row" ] } ], r["priorReviews"]
    assert r["headMoved"]
    assert r["priorThreadsSettled"]
    assert r["secondRound"]
  end

  def test_not_second_round_on_the_same_head
    r = code_review_round(head: "aaaaaaa")
    refute r["headMoved"]
    refute r["secondRound"]
  end

  def test_not_second_round_while_a_prior_thread_is_open
    r = code_review_round(head: "bbbbbbb", resolved: false)
    refute r["priorThreadsSettled"]
    refute r["secondRound"]
  end

  def test_outdated_open_prior_thread_counts_as_settled
    r = code_review_round(head: "bbbbbbb", resolved: false, outdated: true)
    assert r["priorThreadsSettled"]
    assert r["secondRound"]
  end

  def test_fixed_reply_review_is_not_a_prior_code_review
    r = code_review_round(head: "bbbbbbb", header: "Fixed in 4a0c408. Theme blocks now inherit.")
    assert_empty r["priorReviews"]
    refute r["headMoved"]
    refute r["priorThreadsSettled"]
    refute r["secondRound"]
  end

  def test_prior_review_with_no_threads_is_vacuously_settled
    reviews = [ review(VIEWER, "aaaaaaa", id: "PRR_cr", comments: [ "**🔴 P1 - Crash**" ]) ]
    r = history(reviews: reviews, threads: [], head: "bbbbbbb")["reviewRound"]
    assert r["priorThreadsSettled"]
    assert r["secondRound"]
  end

  # Titles come from the round's own finding headers, every tier, so the
  # second round never needs a REST call to read them.
  def test_prior_review_titles_cover_every_tier_and_skip_non_findings
    comments = [ "**🔴 P1 - Crash on nil**\n\nScenario.", "**🟠 P2 - Missing row**",
                 "**🟢 P3 - Rename helper**  \nMore.", "Fixed in 4a0c408. Not a finding.",
                 "**Root cause review - Not a finding header**" ]
    reviews = [ review(VIEWER, "aaaaaaa", id: "PRR_t", comments: comments) ]
    prior = history(reviews: reviews, threads: [], head: "bbbbbbb")["reviewRound"]["priorReviews"].first
    assert_equal [ "Crash on nil", "Missing row", "Rename helper" ], prior["titles"]
  end

  # -- 11b. entity identity contract --------------------------------------------

  # Every entity kind the history emits, with the identity it must carry.
  # A consumer keys on these fields, so none may be dropped from any kind:
  # node ids feed GraphQL, database ids feed REST, and reviewer, commit and
  # time say whose entity it is and when.
  def identity_history
    reviews = [ review(VIEWER, "aaaaaaa", id: "PRR_cr", comments: [ "**🔴 P1 - Crash**" ]), *round2_reviews ]
    history(reviews: reviews, head: "e068235",
            threads: round1_threads(fixed: true) + round2_threads + [ deferred_thread ])
  end

  ENTITY_KINDS = {
    "threads" => [ ->(h) { h["threads"] }, ThreadHistory::THREAD_IDENTITY, %w[threadId reviewId], %w[commentId] ],
    "deferred" => [ ->(h) { h["deferred"] }, ThreadHistory::THREAD_IDENTITY, %w[threadId reviewId], %w[commentId] ],
    "priorThreads" => [ ->(h) { h["priorThreads"] }, ThreadHistory::THREAD_IDENTITY, %w[threadId reviewId], %w[commentId] ],
    "reviewRound.priorReviews" => [ ->(h) { h["reviewRound"]["priorReviews"] }, ThreadHistory::REVIEW_IDENTITY, %w[id], %w[databaseId] ]
  }.freeze

  def test_every_entity_kind_carries_its_whole_identity
    h = identity_history
    ENTITY_KINDS.each do |kind, (pick, keys, node_ids, db_ids)|
      entries = pick.call(h)
      refute_empty entries, kind
      entries.each do |e|
        keys.each { |k| refute_nil e[k], "#{kind} #{e['threadId'] || e['id']} dropped #{k}" }
        node_ids.each { |k| assert_kind_of String, e[k], "#{kind}.#{k} is a node id" }
        db_ids.each { |k| assert_kind_of Integer, e[k], "#{kind}.#{k} is a REST database id" }
      end
    end
  end

  # Each identity field is selected by the query on the node it comes from.
  def test_query_selects_every_identity_source_field
    review_nodes = ThreadHistory::QUERY[/reviews\(first: 100.*?nodes \{(.*?)comments/m, 1]
    %w[id databaseId author commit submittedAt].each { |f| assert_match(/^\s*#{f}\b/, review_nodes, "review #{f}") }
    thread_comments = ThreadHistory::QUERY[/reviewThreads.*?comments\(first: 100\).*?nodes \{(.*?pullRequestReview[^\n]*)/m, 1]
    %w[id databaseId author createdAt pullRequestReview].each do |f|
      assert_match(/^\s*#{f}\b/, thread_comments, "thread comment #{f}")
    end
    assert_match(/pullRequestReview \{ id commit \{ oid \} \}/, thread_comments)
  end

  # -- 12. consolidatedAtHead ---------------------------------------------------

  def test_consolidated_at_head_only_on_the_head_commit
    body = "**Root cause review - Use a tokenizer**\n\nSummary."
    at_head = history(reviews: [ review(VIEWER, "bbbbbbb", body: body) ], threads: [], head: "bbbbbbb")
    older = history(reviews: [ review(VIEWER, "aaaaaaa", body: body) ], threads: [], head: "bbbbbbb")
    other = history(reviews: [ review(CODEX, "bbbbbbb", body: body) ], threads: [], head: "bbbbbbb")
    assert at_head["reviewRound"]["consolidatedAtHead"]
    refute older["reviewRound"]["consolidatedAtHead"]
    refute other["reviewRound"]["consolidatedAtHead"]
  end

  # -- 13. contract cross-checks ------------------------------------------------

  def test_fixed_and_deferred_patterns
    assert_equal "4a0c408", "Fixed in 4a0c408. Theme blocks"[ThreadHistory::FIXED, 1]
    assert_equal "pr-237-css-parsing", "Deferred to plan pr-237-css-parsing. x"[ThreadHistory::DEFERRED, 1]
    refute_match ThreadHistory::FIXED, "Leaving this as is on purpose."
  end

  def test_finding_header_matches_the_finding_renderer
    %w[P1 P2 P3].each do |tier|
      body = RenderFindingComment.new("tier" => tier, "title" => "Missing row", "scenario" => "x").render
      assert_match ThreadHistory::FINDING_HEADER, body
    end
  end

  def test_consolidated_header_matches_the_round_renderer
    body = RenderRoundReview.new("title" => "Use a tokenizer", "summary" => "s", "handoff" => "h").render
    assert_match ThreadHistory::CONSOLIDATED_HEADER, body
  end

  # -- 14. truncated ------------------------------------------------------------

  def test_truncated_when_either_connection_has_a_next_page
    refute history(reviews: [], threads: [], head: "a")["truncated"]
    assert history(reviews: [], threads: [], head: "a", review_next: true)["truncated"]
    assert history(reviews: [], threads: [], head: "a", thread_next: true)["truncated"]
  end

  # Every connection the query reads is a member of the class: the two
  # top-level ones and the comments nested under a review or a thread.
  def test_truncated_when_a_nested_comments_connection_has_a_next_page
    more = { "hasNextPage" => true }
    long_review = review(CODEX, "567bce1", comments: [ "x" ])
    long_review["comments"]["pageInfo"] = more
    assert history(reviews: [ long_review ], threads: [], head: "a")["truncated"]

    long_thread = round1_threads(fixed: false).first
    long_thread["comments"]["pageInfo"] = more
    assert history(reviews: [], threads: [ long_thread ], head: "a")["truncated"]

    review_done = review(CODEX, "567bce1", comments: [ "x" ])
    review_done["comments"]["pageInfo"] = { "hasNextPage" => false }
    refute history(reviews: [ review_done ], threads: round1_threads(fixed: false), head: "a")["truncated"]
  end

  # -- 15. parse_ref ------------------------------------------------------------

  def test_parse_ref
    assert_equal [ "o", "r", 12 ], ThreadHistory.parse_ref("https://github.com/o/r/pull/12")
    assert_equal [ "o", "r", 12 ], ThreadHistory.parse_ref("https://github.com/o/r/pull/12/files")
    assert_equal [ "o", "r", 12 ], ThreadHistory.parse_ref("o/r#12")
    assert_equal [ nil, nil, 12 ], ThreadHistory.parse_ref("#12")
    assert_equal [ nil, nil, 12 ], ThreadHistory.parse_ref("12")
    assert_nil ThreadHistory.parse_ref("not a pr")
    assert_nil ThreadHistory.parse_ref("https://example.com/o/r/pull/12")
  end

  # -- 16. CLI ------------------------------------------------------------------

  Status = Struct.new(:ok) do
    def success? = ok
  end

  def fake_runner(responses)
    calls = []
    runner = lambda do |*argv|
      calls << argv
      key = argv[1]
      responses.fetch(key)
    end
    [ runner, calls ]
  end

  def run_cli(argv, responses)
    runner, calls = fake_runner(responses)
    out = StringIO.new
    err = StringIO.new
    code = ThreadHistory::CLI.run(argv, out: out, err: err, runner: runner)
    [ code, out.string, err.string, calls ]
  end

  def canned_graphql
    JSON.generate("data" => data(reviews: [ review(CODEX, "567bce1") ], threads: round1_threads(fixed: false), head: "567bce1"))
  end

  def test_cli_prints_json_and_returns_zero
    code, out, err, calls = run_cli([ "#237" ], "repo" => [ "change-fabric/change-fabric\n", Status.new(true) ],
                                                "api" => [ canned_graphql, Status.new(true) ])
    assert_equal 0, code
    assert_equal "", err
    parsed = JSON.parse(out)
    assert_equal 237, parsed["pr"]
    assert_equal 4, parsed["threads"].size
    graphql = calls.find { |c| c[1] == "api" }
    assert_includes graphql, "owner=change-fabric"
    assert_includes graphql, "name=change-fabric"
    assert_includes graphql, "number=237"
    assert_includes graphql, "query=#{ThreadHistory::QUERY}"
  end

  def test_cli_with_no_ref_uses_the_current_branch_pr
    pr = JSON.generate("number" => 237, "url" => "https://github.com/change-fabric/change-fabric/pull/237")
    code, _out, _err, calls = run_cli([], "pr" => [ pr, Status.new(true) ], "api" => [ canned_graphql, Status.new(true) ])
    assert_equal 0, code
    assert_equal [ "gh", "pr", "view", "--json", "number,url" ], calls.first
    refute(calls.any? { |c| c[1] == "repo" })
  end

  # -- 17. pagination -----------------------------------------------------------

  def page(reviews:, threads:, review_cursor: nil, thread_cursor: nil)
    d = data(reviews: reviews || [], threads: threads || [], head: "e24f742",
             review_next: !review_cursor.nil?, thread_next: !thread_cursor.nil?)
    pr = d["repository"]["pullRequest"]
    pr["reviews"]["pageInfo"]["endCursor"] = review_cursor
    pr["reviewThreads"]["pageInfo"]["endCursor"] = thread_cursor
    pr.delete("reviews") if reviews.nil?
    pr.delete("reviewThreads") if threads.nil?
    JSON.generate("data" => d)
  end

  def run_paged(pages)
    queue = pages.dup
    calls = []
    runner = lambda do |*argv|
      calls << argv
      raise "unexpected extra graphql call" if queue.empty?

      [ queue.shift, Status.new(true) ]
    end
    out = StringIO.new
    code = ThreadHistory::CLI.run([ "o/r#237" ], out: out, err: StringIO.new, runner: runner)
    [ code, JSON.parse(out.string), calls ]
  end

  def vars(call)
    call.each_cons(2).filter_map { |flag, kv| kv if %w[-f -F].include?(flag) && !kv.start_with?("query=") }
  end

  # Each variant of a connection outrunning one page: threads only, reviews
  # only, both at once, and both with different page counts.
  def test_cli_follows_thread_cursors_and_drops_the_exhausted_reviews
    t1, t2 = round2_threads.each_slice(2).to_a
    code, h, calls = run_paged([ page(reviews: round2_reviews, threads: t1, thread_cursor: "T1"),
                                 page(reviews: nil, threads: t2) ])
    assert_equal 0, code
    assert_equal 2, calls.size
    assert_includes vars(calls[1]), "threadsAfter=T1"
    assert_includes vars(calls[1]), "withReviews=false"
    assert_equal 4, h["threads"].size
    refute h["truncated"]
  end

  def test_cli_follows_review_cursors_and_drops_the_exhausted_threads
    r1, r2 = round2_reviews.each_slice(3).to_a
    threads = round1_threads(fixed: true) + round2_threads
    code, h, calls = run_paged([ page(reviews: r1, threads: threads, review_cursor: "R1"),
                                 page(reviews: r2, threads: nil) ])
    assert_equal 0, code
    assert_includes vars(calls[1]), "reviewsAfter=R1"
    assert_includes vars(calls[1]), "withThreads=false"
    assert_equal({ CODEX => 2 }, h["rounds"])
    assert h["recurrence"]["fired"]
    refute h["truncated"]
  end

  def test_cli_follows_both_cursors_until_each_is_exhausted
    r1, r2, r3 = round2_reviews.each_slice(2).to_a
    t1, t2 = (round1_threads(fixed: true) + round2_threads).each_slice(4).to_a
    code, h, calls = run_paged([ page(reviews: r1, threads: t1, review_cursor: "R1", thread_cursor: "T1"),
                                 page(reviews: r2, threads: t2, review_cursor: "R2"),
                                 page(reviews: r3, threads: nil) ])
    assert_equal 0, code
    assert_equal 3, calls.size
    assert_includes vars(calls[1]), "reviewsAfter=R1"
    assert_includes vars(calls[1]), "threadsAfter=T1"
    assert_includes vars(calls[2]), "reviewsAfter=R2"
    assert_includes vars(calls[2]), "withThreads=false"
    refute(vars(calls[2]).any? { |v| v.start_with?("threadsAfter=") })
    assert_equal 4, h["threads"].size
    assert_equal 4, h["priorThreads"].size
    assert_equal({ CODEX => 2 }, h["rounds"])
    refute h["truncated"]
  end

  def test_cli_stops_at_the_page_cap_and_reports_truncated
    pages = Array.new(ThreadHistory::MAX_PAGES) do |i|
      page(reviews: nil, threads: [ round2_threads.first.merge("id" => "PRRT_#{i}") ], thread_cursor: "T#{i}")
    end
    pages[0] = page(reviews: [], threads: [ round2_threads.first ], thread_cursor: "T0")
    code, h, calls = run_paged(pages)
    assert_equal 0, code
    assert_equal ThreadHistory::MAX_PAGES, calls.size
    assert h["truncated"]
  end

  def test_cli_returns_one_and_writes_stderr_when_gh_fails
    code, out, err, = run_cli([ "o/r#12" ], "api" => [ "HTTP 401: Bad credentials\n", Status.new(false) ])
    assert_equal 1, code
    assert_equal "", out
    assert_includes err, "Bad credentials"
  end

  def test_cli_rejects_an_unrecognized_ref
    code, _out, err, calls = run_cli([ "nope" ], {})
    assert_equal 1, code
    assert_includes err, "unrecognized PR ref"
    assert_empty calls
  end
end
