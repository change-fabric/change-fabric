#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

SKILL_SCRIPTS = File.expand_path("../scripts", __dir__)
require_relative "#{SKILL_SCRIPTS}/skill_registry"
require_relative "#{SKILL_SCRIPTS}/skill_store"
require_relative "#{SKILL_SCRIPTS}/review_queue"
require_relative "#{SKILL_SCRIPTS}/skill_inject"
require_relative "#{SKILL_SCRIPTS}/skill_detect"
require_relative "#{SKILL_SCRIPTS}/skill_review"

REPO_SKILLS = File.expand_path("../skills", __dir__)

module SkillTempHome
  def setup
    @home = Dir.mktmpdir
    @prev_home = Dir.home
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @prev_home
    FileUtils.remove_entry(@home)
  end
end

# Builds throwaway skill directories so matching/detection edge cases can be
# exercised without depending on the shipped cheat sheets.
module SkillFactory
  def skill_dir(name, auto:, body: "BODY-#{name}")
    front = { "name" => name, "description" => "x", "auto" => auto }
    write_skill(name, "---\n#{front.to_yaml.sub(/\A---\n/, '')}---\n\n#{body}\n")
  end

  def plain_skill(name)
    write_skill(name, "---\nname: #{name}\ndescription: plain\n---\n\nNo auto block.\n")
  end

  def write_skill(name, contents)
    dir = File.join(@skills, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), contents)
  end
end

class SkillRegistryTest < Minitest::Test
  include SkillFactory

  def setup
    @skills = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@skills)
  end

  def load = SkillRegistry.load(@skills)

  def test_loads_only_skills_with_an_auto_block
    skill_dir("ruby", auto: { "extensions" => [ "rb" ] })
    plain_skill("pst")
    assert_equal [ "ruby" ], load.map(&:name)
  end

  def test_matches_by_extension_case_insensitively
    skill_dir("ruby", auto: { "extensions" => [ "rb" ] })
    skill = load.first
    assert skill.matches?("/proj/lib/foo.RB")
    refute skill.matches?("/proj/README.md")
  end

  def test_matches_by_basename
    skill_dir("ruby", auto: { "extensions" => [ "rb" ], "basenames" => [ "Rakefile" ] })
    assert load.first.matches?("/proj/Rakefile")
  end

  def test_detected_by_marker_file
    skill_dir("ruby", auto: { "detect" => [ "Gemfile", "*.gemspec" ] })
    proj = Dir.mktmpdir
    refute load.first.detected?(proj)
    FileUtils.touch(File.join(proj, "Gemfile"))
    assert load.first.detected?(proj)
  ensure
    FileUtils.remove_entry(proj)
  end

  def test_universal_skill_is_always_detected
    skill_dir("refactoring", auto: { "universal" => true })
    assert load.first.detected?(Dir.mktmpdir)
  end

  def test_review_flag_is_read
    skill_dir("ruby", auto: { "extensions" => [ "rb" ], "review" => true })
    skill_dir("refactoring", auto: { "extensions" => [ "rb" ] })
    by_name = load.to_h { |s| [ s.name, s ] }
    assert by_name["ruby"].review?
    refute by_name["refactoring"].review?
  end

  def test_malformed_skill_is_skipped_not_fatal
    dir = File.join(@skills, "broken")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), "---\n: : not yaml :\n---\nbody")
    assert_equal [], load
  end

  def test_shipped_skills_parse_and_declare_intended_rules
    skills = SkillRegistry.load(REPO_SKILLS).to_h { |s| [ s.name, s ] }
    assert skills["ruby"].review?, "ruby should request haiku review"
    refute skills["refactoring"].review?, "refactoring should only surface its sheet"
    assert skills["refactoring"].universal?, "refactoring applies to any code project"
    assert skills["ruby"].matches?("app/models/user.rb")
    assert skills["refactoring"].matches?("src/main.go")
  end
end

class SkillStoreTest < Minitest::Test
  include SkillTempHome

  def test_fresh_returns_unrecorded_then_marks_them
    store = SkillStore.new("s1")
    assert_equal %w[a b], store.fresh(%w[a b])
    store.mark(%w[a])
    assert_equal %w[b], store.fresh(%w[a b])
  end

  def test_keys_are_independent
    SkillStore.new("s1", "surfaced").mark(%w[a])
    assert_equal %w[a], SkillStore.new("s1", "announced").fresh(%w[a])
  end

  def test_record_is_newline_terminated_and_separated
    SkillStore.new("s1").mark(%w[ruby])
    SkillStore.new("s1").mark(%w[refactoring])
    path = File.join(@home, ".claude", "pst", "sessions", "s1", "skills-surfaced")
    assert_equal "ruby\nrefactoring\n", File.read(path)
  end

  def test_blank_session_never_persists
    store = SkillStore.new("")
    store.mark(%w[a])
    assert_equal %w[a], store.fresh(%w[a])
    assert_empty Dir.glob(File.join(@home, ".claude", "pst", "sessions", "**", "*"))
  end
end

class SkillInjectTest < Minitest::Test
  include SkillTempHome
  include SkillFactory

  def setup
    super
    @skills = Dir.mktmpdir
    @proj = Dir.mktmpdir
    skill_dir("ruby", auto: { "extensions" => [ "rb" ], "review" => true })
    skill_dir("refactoring", auto: { "extensions" => [ "rb", "go" ] })
  end

  def teardown
    FileUtils.remove_entry(@skills)
    FileUtils.remove_entry(@proj)
    super
  end

  def context(tool:, path:, session: "s1")
    io = StringIO.new
    event = { "session_id" => session, "tool_name" => tool, "tool_input" => { "file_path" => path } }
    SkillInject.new(event, skills: SkillRegistry.load(@skills)).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "additionalContext")
  end

  # Writes a real file (enqueue hashes its content) and runs the hook on it.
  def edit(name, content: "x", tool: "Edit", session: "s1")
    path = File.join(@proj, name)
    File.write(path, content)
    context(tool: tool, path: path, session: session)
    path
  end

  def test_surfaces_matching_skills_for_a_ruby_edit
    text = context(tool: "Edit", path: "/p/foo.rb")
    assert_includes text, "ruby"
    assert_includes text, "refactoring"
  end

  def test_surfacing_carries_no_review_directive
    text = context(tool: "Write", path: "/p/foo.rb")
    refute_includes text, "haiku"
    refute_includes text, "background review agent"
  end

  def test_only_matching_skills_surface_for_a_foreign_type
    text = context(tool: "Edit", path: "/p/main.go")
    assert_includes text, "refactoring"
    refute_includes text, "ruby"
  end

  def test_review_enabled_edits_are_queued_with_a_content_hash
    a = edit("foo.rb")
    b = edit("bar.rb")
    queued = ReviewQueue.new("s1").drain
    assert_equal [ "ruby" ], queued.map { |q| q[:skill] }.uniq
    assert_equal [ a, b ], queued.map { |q| q[:path] }
    assert(queued.all? { |q| q[:hash].to_s.length == 16 }, "each entry carries a content hash")
  end

  def test_re_editing_same_content_does_not_grow_the_queue
    edit("foo.rb", content: "same")
    edit("foo.rb", content: "same")
    assert_equal 1, ReviewQueue.new("s1").drain.size
  end

  def test_non_review_skill_does_not_queue
    edit("main.go")
    assert_empty ReviewQueue.new("s1").drain
  end

  def test_surfaces_each_skill_at_most_once_per_session
    assert context(tool: "Edit", path: "/p/a.rb")
    assert_nil context(tool: "Edit", path: "/p/b.rb"), "second ruby edit should be silent"
  end

  def test_ignores_non_edit_tools
    assert_nil context(tool: "Bash", path: "/p/foo.rb")
  end

  def test_ignores_unmatched_file_types
    assert_nil context(tool: "Edit", path: "/p/README.md")
  end

  def test_reads_notebook_path
    io = StringIO.new
    event = { "session_id" => "s1", "tool_name" => "NotebookEdit",
              "tool_input" => { "notebook_path" => "/p/x.rb" } }
    SkillInject.new(event, skills: SkillRegistry.load(@skills)).emit(io)
    refute_empty io.string
  end
end

class SkillDetectTest < Minitest::Test
  include SkillTempHome
  include SkillFactory

  def setup
    super
    @skills = Dir.mktmpdir
    @proj = Dir.mktmpdir
    skill_dir("ruby", auto: { "detect" => [ "Gemfile" ] })
    skill_dir("refactoring", auto: { "universal" => true })
    skill_dir("python", auto: { "detect" => [ "pyproject.toml" ] })
  end

  def teardown
    FileUtils.remove_entry(@skills)
    FileUtils.remove_entry(@proj)
    super
  end

  def announce(session: "s1")
    io = StringIO.new
    event = { "session_id" => session, "cwd" => @proj }
    SkillDetect.new(event, skills: SkillRegistry.load(@skills)).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "additionalContext")
  end

  def test_announces_universal_and_detected_skills_only
    FileUtils.touch(File.join(@proj, "Gemfile"))
    text = announce
    assert_includes text, "ruby"
    assert_includes text, "refactoring"
    refute_includes text, "python"
  end

  def test_announces_once_per_session
    FileUtils.touch(File.join(@proj, "Gemfile"))
    assert announce
    assert_nil announce, "second SessionStart should not re-announce"
  end
end

class ReviewQueueTest < Minitest::Test
  include SkillTempHome

  def test_drain_clears_the_queue
    queue = ReviewQueue.new("s1")
    queue.add("ruby", "/p/a.rb", "h1")
    queue.add("ruby", "/p/b.rb", "h1")
    assert_equal %w[/p/a.rb /p/b.rb], queue.drain.map { |e| e[:path] }
    assert_empty ReviewQueue.new("s1").drain, "drain should empty the queue"
  end

  def test_dedupes_by_path_keeping_latest_hash
    queue = ReviewQueue.new("s1")
    queue.add("ruby", "/p/a.rb", "h1")
    queue.add("ruby", "/p/a.rb", "h2")
    rows = queue.drain
    assert_equal 1, rows.size
    assert_equal "h2", rows.first[:hash]
  end

  def test_skips_content_already_reviewed_then_requeues_new_content
    queue = ReviewQueue.new("s1")
    queue.mark_reviewed([ { skill: "ruby", path: "/p/a.rb", hash: "h1" } ])
    queue.add("ruby", "/p/a.rb", "h1")
    assert_empty queue.drain, "same content must not re-queue"
    queue.add("ruby", "/p/a.rb", "h2")
    assert_equal [ "h2" ], queue.drain.map { |e| e[:hash] }
  end

  def test_round_cap_trips_after_cap_rounds
    queue = ReviewQueue.new("s1")
    refute queue.capped?
    ReviewQueue::CAP.times { queue.bump_round }
    assert queue.capped?
  end

  def test_blank_session_stays_empty
    queue = ReviewQueue.new("")
    queue.add("ruby", "/p/a.rb", "h1")
    assert_empty queue.drain
  end
end

class SkillReviewTest < Minitest::Test
  include SkillTempHome
  include SkillFactory

  def setup
    super
    @skills = Dir.mktmpdir
    skill_dir("ruby", auto: { "extensions" => [ "rb" ], "review" => true },
                      body: "POODR-PRINCIPLES")
  end

  def teardown
    FileUtils.remove_entry(@skills)
    super
  end

  def review(session: "s1", stop_active: false)
    io = StringIO.new
    event = { "session_id" => session, "stop_hook_active" => stop_active }
    SkillReview.new(event, skills: SkillRegistry.load(@skills)).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string)
  end

  def enqueue(path, hash)
    ReviewQueue.new("s1").add("ruby", path, hash)
  end

  def test_no_block_when_queue_empty
    assert_nil review
  end

  def test_blocks_with_fixed_prompt_embedding_files_and_principles
    enqueue("/p/user.rb", "h1")
    out = review
    assert_equal "block", out["decision"]
    assert_includes out["reason"], "/p/user.rb"
    assert_includes out["reason"], "POODR-PRINCIPLES"
    assert_includes out["reason"], "run_in_background: true"
  end

  def test_fires_once_per_batch
    enqueue("/p/user.rb", "h1")
    assert review, "first stop should block for review"
    assert_nil review, "queue drained, second stop should not block"
  end

  def test_respects_stop_hook_active_guard
    enqueue("/p/user.rb", "h1")
    assert_nil review(stop_active: true), "must not block while already continuing"
  end

  # The loop the integration test surfaced: review -> fix -> re-edit. A fix that
  # leaves identical content must not re-queue; a genuinely new change must.
  def test_converges_then_retriggers_on_new_content
    enqueue("/p/user.rb", "h1")
    assert_equal "block", review["decision"], "round 1: find"
    ReviewQueue.new("s1").add("ruby", "/p/user.rb", "h1") # same content as reviewed
    assert_nil review, "identical content must not start another round"
    ReviewQueue.new("s1").add("ruby", "/p/user.rb", "h2") # a later, real change
    assert_equal "block", review["decision"], "new content re-triggers a review"
  end

  def test_round_cap_surfaces_a_visible_notice_instead_of_blocking
    ReviewQueue::CAP.times do |i|
      enqueue("/p/f#{i}.rb", "h#{i}")
      assert_equal "block", review["decision"], "round #{i + 1} should block"
    end
    enqueue("/p/extra.rb", "hx")
    out = review
    assert_nil out["decision"], "must not block once capped"
    assert_includes out["systemMessage"], "Round cap"
  end
end
