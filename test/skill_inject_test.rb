# frozen_string_literal: true

require_relative "test_helpers"

class SkillInjectTest < Minitest::Test
  include SkillTempHome
  include SkillFactory

  def setup
    super
    @skills = Dir.mktmpdir
    @proj = Dir.mktmpdir
    system("git", "init", "-q", @proj) # enqueue only tracks files inside a work tree
    skill_dir("ruby", auto: { "extensions" => [ "rb" ] })
    skill_dir("refactoring", auto: { "all_code" => true })
    skill_dir("ai-slop", auto: { "all_files" => true })
  end

  def teardown
    FileUtils.remove_entry(@skills)
    FileUtils.remove_entry(@proj)
    super
  end

  def registry = SkillRegistry.load(@skills)

  def context(tool:, path:, session: "s1", skills: nil)
    io = StringIO.new
    event = { "session_id" => session, "tool_name" => tool, "tool_input" => { "file_path" => path } }
    SkillInject.new(event, skills: skills || registry).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "additionalContext")
  end

  # Writes a real file (enqueue hashes its content) and runs the hook on it.
  def edit(name, content: "x", tool: "Edit", session: "s1")
    path = File.join(@proj, name)
    File.write(path, content)
    context(tool: tool, path: path, session: session)
    path
  end

  def test_ruby_edit_surfaces_every_matching_skill
    text = context(tool: "Edit", path: "/p/foo.rb")
    assert_includes text, "ruby"
    assert_includes text, "refactoring"
    assert_includes text, "ai-slop"
  end

  def test_surfacing_carries_no_review_directive
    text = context(tool: "Write", path: "/p/foo.rb")
    refute_includes text, "haiku"
    refute_includes text, "background review agent"
  end

  def test_prose_edit_surfaces_only_all_files_skill
    text = context(tool: "Edit", path: "/p/README.md")
    assert_includes text, "ai-slop"
    refute_includes text, "ruby"
    refute_includes text, "refactoring"
  end

  def test_emits_nothing_when_no_skill_matches
    only_ruby = registry.select { |s| s.name == "ruby" }
    assert_nil context(tool: "Edit", path: "/p/README.md", skills: only_ruby)
  end

  def test_every_matching_skill_is_queued_with_a_content_hash
    edit("foo.rb")
    queued = ReviewQueue.new("s1").pending
    assert_equal %w[ai-slop refactoring ruby], queued.map { |q| q[:skill] }.uniq.sort
    assert(queued.all? { |q| q[:hash].to_s.length == 16 }, "each entry carries a content hash")
  end

  def test_prose_change_queues_the_all_files_skill
    edit("notes.md")
    assert_equal %w[ai-slop], ReviewQueue.new("s1").pending.map { |q| q[:skill] }.uniq
  end

  def test_re_editing_same_content_does_not_grow_the_queue
    edit("foo.rb", content: "same")
    edit("foo.rb", content: "same")
    assert_equal 3, ReviewQueue.new("s1").pending.size, "ruby + refactoring + ai-slop, one entry each"
  end

  def test_surfaces_each_skill_at_most_once_per_session
    assert context(tool: "Edit", path: "/p/a.rb")
    assert_nil context(tool: "Edit", path: "/p/b.rb"), "second edit should be silent"
  end

  def test_ignores_non_edit_tools
    assert_nil context(tool: "Bash", path: "/p/foo.rb")
  end

  def test_file_outside_any_repo_is_not_enqueued
    outside = Dir.mktmpdir
    path = File.join(outside, "scratch.rb")
    File.write(path, "x")
    assert context(tool: "Edit", path: path), "cheat sheet still surfaces for any edit"
    assert_empty ReviewQueue.new("s1").pending, "out-of-repo file must not arm the gate"
  ensure
    FileUtils.remove_entry(outside)
  end

  def test_git_ignored_file_is_not_enqueued
    File.write(File.join(@proj, ".gitignore"), "ignored.rb\n")
    edit("ignored.rb")
    assert_empty ReviewQueue.new("s1").pending, "git-ignored file must not arm the gate"
  end

  def test_excluded_skill_not_surfaced_in_conflicting_project
    skill_dir("drz", auto: { "paths" => [ "**/schema.ts" ], "exclude" => [ "**/schema.prisma" ] })
    FileUtils.mkdir_p(File.join(@proj, "prisma"))
    File.write(File.join(@proj, "prisma", "schema.prisma"), "x")
    path = File.join(@proj, "src", "schema.ts")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "x")
    text = context(tool: "Edit", path: path)
    refute_includes text.to_s, "drz", "drizzle must not surface in a Prisma project"
    # Enqueue is structural, so drz does enter the raw queue; the final-tree
    # gate (review_scope) is what drops it from the review that arms the gate.
    pending = ReviewQueue.new("s1").pending
    assert_includes pending.map { |q| q[:skill] }, "drz", "structural enqueue is ungated"
    refute_includes ReviewScope.covered(pending, registry).map { |q| q[:skill] }, "drz",
                    "the final-tree exclude marker drops it from review"
  end

  def test_excluded_skill_surfaced_when_no_conflict
    skill_dir("drz", auto: { "paths" => [ "**/schema.ts" ], "exclude" => [ "**/schema.prisma" ] })
    path = File.join(@proj, "src", "schema.ts")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "x")
    assert_includes context(tool: "Edit", path: path).to_s, "drz"
  end

  def test_file_authored_before_its_require_marker_is_still_reviewed
    skill_dir("drz", auto: { "paths" => [ "**/schema.js" ], "require" => [ "**/drizzle.config.js" ] })
    schema = File.join(@proj, "src", "db", "schema.js")
    FileUtils.mkdir_p(File.dirname(schema))
    File.write(schema, "x")
    # Edit happens before the marker exists: structural enqueue still captures it,
    # even though the require gate is unsatisfied at this instant.
    context(tool: "Edit", path: schema)
    pending = ReviewQueue.new("s1").pending
    assert_includes pending.map { |q| q[:skill] }, "drz", "structural enqueue is ungated"
    refute_includes ReviewScope.covered(pending, registry).map { |q| q[:skill] }, "drz",
                    "with no marker yet, the final-tree gate drops it"

    # The marker now appears; the final-tree gate admits the earlier file.
    File.write(File.join(@proj, "drizzle.config.js"), "x")
    covered = ReviewScope.covered(ReviewQueue.new("s1").pending, registry)
    assert_includes covered.map { |q| q[:skill] }, "drz",
                    "once the marker exists, the file authored before it is reviewed"
  end

  def test_unresolved_root_does_not_suppress
    skill_dir("drz", auto: { "paths" => [ "**/schema.ts" ], "exclude" => [ "**/schema.prisma" ] })
    outside = Dir.mktmpdir # not a git work tree, so the root cannot resolve
    FileUtils.mkdir_p(File.join(outside, "prisma"))
    File.write(File.join(outside, "prisma", "schema.prisma"), "x")
    path = File.join(outside, "schema.ts")
    File.write(path, "x")
    assert_includes context(tool: "Edit", path: path).to_s, "drz",
                    "an unresolved root skips exclusion, so the skill still surfaces"
  ensure
    FileUtils.remove_entry(outside) if outside
  end

  def test_reads_notebook_path
    io = StringIO.new
    event = { "session_id" => "s1", "tool_name" => "NotebookEdit",
              "tool_input" => { "notebook_path" => "/p/x.rb" } }
    SkillInject.new(event, skills: registry).emit(io)
    refute_empty io.string
  end
end
