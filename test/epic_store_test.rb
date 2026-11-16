# frozen_string_literal: true

require_relative "test_helpers"
require "digest"
require_relative "#{SKILL_SCRIPTS}/epic_store"

class EpicStoreTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/epic", __dir__)
  CLEAN = File.join(FIXTURES, "clean/epic.md")
  PLANS = File.join(FIXTURES, "clean/plans")

  def load_text(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "epic.md")
      File.write(path, text)
      EpicStore.load(path, plans_root: PLANS)
    end
  end

  def test_clean_fixture_parses_every_field
    epic = EpicStore.load(CLEAN, plans_root: PLANS)

    assert_empty epic.problems
    assert_match(/sign in once/, epic.goal)
    assert_equal 1, epic.epic_rev
    assert_equal %w[sample-org/api sample-org/web other-org/shared-lib], epic.repos
    assert_equal %w[P1 P2 P3 P4], epic.plans.map { |plan| plan["id"] }
    assert_equal [ "app/auth/**" ], epic.plans[1]["paths"]
    assert_equal 3, epic.edges.size
    assert_equal %w[SC1 SC2 SC3], epic.criteria.map { |criterion| criterion["id"] }
    assert_equal %w[P1 P2 P3 P4], epic.digests.keys
    assert_match(/Synthetic example epic/, epic.body)
  end

  def test_fixture_digests_match_the_plan_files
    epic = EpicStore.load(CLEAN, plans_root: PLANS)

    epic.plans.each do |plan|
      actual = Digest::SHA256.file(EpicStore.plan_md_path(epic, plan)).hexdigest
      assert_equal epic.digests[plan["id"]], actual, plan["id"]
    end
  end

  def test_non_mapping_frontmatter_is_one_problem_not_an_exception
    epic = load_text("---\n- just\n- a list\n---\nbody\n")

    assert_equal [ "frontmatter: not a mapping" ], epic.problems
    assert_empty epic.plans
  end

  def test_malformed_yaml_is_one_problem
    epic = load_text("---\ngoal: [unclosed\n---\n")

    assert_equal 1, epic.problems.size
    assert_match(/\Afrontmatter: invalid YAML/, epic.problems.first)
  end

  def test_missing_frontmatter_is_one_problem
    assert_equal [ "frontmatter: no YAML frontmatter block" ], load_text("no frontmatter\n").problems
  end

  def test_non_list_fields_and_non_mapping_entries_are_problems
    epic = load_text("---\nrepos: sample-org/api\nplans:\n  - P1\nedges: {a: b}\ndigests: [x]\n---\n")

    assert_includes epic.problems, "frontmatter: repos must be a list"
    assert_includes epic.problems, "frontmatter: edges must be a list"
    assert_includes epic.problems, "frontmatter: plans[0] must be a mapping"
    assert_includes epic.problems, "frontmatter: digests must be a mapping"
    assert_empty epic.plans
  end

  def test_safe_load_rejects_ruby_objects
    epic = load_text("---\ngoal: !ruby/object:Object {}\n---\n")

    assert_match(/\Afrontmatter: invalid YAML/, epic.problems.first)
  end

  def test_plan_phases_reads_both_section_names_only
    text = <<~MD
      ## Context
      ### Phase 9: Not a phase, wrong section
      ## Phased rollout
      ### Phase 1: First
      ### Phase 2: Second step
      ## Verification
      ### Phase 7: Also ignored
    MD

    assert_equal [ [ 1, "First" ], [ 2, "Second step" ] ], EpicStore.plan_phases(text)
    assert_equal [ [ 3, "Three" ] ], EpicStore.plan_phases("## Phases\n\n### Phase 3: Three\n")
  end

  def test_phases_for_is_nil_when_plan_md_is_absent
    epic = EpicStore.load(CLEAN, plans_root: PLANS)

    assert_equal [ [ 1, "Record sign ins" ] ], EpicStore.phases_for(epic, epic.plans.last)
    assert_nil EpicStore.phases_for(epic, { "dir" => "demo/nowhere" })
  end

  def test_fenced_examples_are_not_headings
    md = <<~MD
      ## Phases

      ### Phase 1: Parse

      ```markdown
      ## Example output
      ### Phase 9: Not real
      ```

      ### Phase 2: Wire
    MD

    assert_equal [ [ 1, "Parse" ], [ 2, "Wire" ] ], EpicStore.plan_phases(md)
  end

  def test_path_for_resolves_under_the_epics_area
    previous = ENV.fetch("CF_PLANS_ROOT", nil)
    ENV["CF_PLANS_ROOT"] = "/plans-root"

    assert_equal "/plans-root/epics/sso/epic.md", EpicStore.path_for("sso")
  ensure
    previous ? ENV["CF_PLANS_ROOT"] = previous : ENV.delete("CF_PLANS_ROOT")
  end

  def test_write_atomic_replaces_content_and_leaves_no_temp_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nested/epic.md")
      EpicStore.write_atomic(path, "one")
      EpicStore.write_atomic(path, "two")

      assert_equal "two", File.read(path)
      assert_equal [ "epic.md" ], Dir.children(File.dirname(path))
    end
  end
end
