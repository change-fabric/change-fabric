# frozen_string_literal: true

require_relative "test_helpers"

class SkillInjectTest < Minitest::Test
  include SkillTempHome
  include SkillFactory

  def setup
    super
    @skills = Dir.mktmpdir
    @proj = Dir.mktmpdir
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

  def test_reviewed_skills_are_queued_with_a_content_hash
    edit("foo.rb")
    queued = ReviewQueue.new("s1").drain
    assert_equal %w[refactoring ruby], queued.map { |q| q[:skill] }.uniq.sort
    refute_includes queued.map { |q| q[:skill] }, "ai-slop"
    assert(queued.all? { |q| q[:hash].to_s.length == 16 }, "each entry carries a content hash")
  end

  def test_surface_only_skill_does_not_queue
    edit("notes.md")
    assert_empty ReviewQueue.new("s1").drain
  end

  def test_re_editing_same_content_does_not_grow_the_queue
    edit("foo.rb", content: "same")
    edit("foo.rb", content: "same")
    assert_equal 2, ReviewQueue.new("s1").drain.size, "ruby + refactoring, one entry each"
  end

  def test_surfaces_each_skill_at_most_once_per_session
    assert context(tool: "Edit", path: "/p/a.rb")
    assert_nil context(tool: "Edit", path: "/p/b.rb"), "second edit should be silent"
  end

  def test_ignores_non_edit_tools
    assert_nil context(tool: "Bash", path: "/p/foo.rb")
  end

  def test_reads_notebook_path
    io = StringIO.new
    event = { "session_id" => "s1", "tool_name" => "NotebookEdit",
              "tool_input" => { "notebook_path" => "/p/x.rb" } }
    SkillInject.new(event, skills: registry).emit(io)
    refute_empty io.string
  end
end
