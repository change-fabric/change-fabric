# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/skill_compiler"

class SkillCompilerTest < Minitest::Test
  def test_mode_contract_is_shared_by_all_hosts
    source = File.read(File.expand_path("../skills/merge-ready/SKILL.md", __dir__))
    (SkillCompiler::HOSTS - ["claude"]).each do |host|
      compiler = SkillCompiler.new(host: host)
      text = compiler.compile(source)
      assert_includes text, "Stop before merging"
      assert_includes text, compiler.invocation("merge-ready")
      refute_includes text, "has already persisted"
      refute_match(/\{\{skill:/, text)
    end
  end

  # The Claude adapter parses AskUserQuestion headers and skill loads, so every
  # mode skill must keep its native body (and the /cf header schema) there.
  def test_claude_keeps_native_adapter_contract_for_every_mode_skill
    compiler = SkillCompiler.new(host: "claude")
    Dir[File.expand_path("../workflows/modes/*.md", __dir__)].each do |workflow|
      id = File.basename(workflow, ".md")
      source = File.read(File.expand_path("../skills/#{id}/SKILL.md", __dir__))
      _, body = SkillRegistry::Frontmatter.split(source)
      assert_includes compiler.compile(source), body.strip, "claude #{id} lost its native body"
    end
    cf = compiler.compile(File.read(File.expand_path("../skills/cf/SKILL.md", __dir__)))
    assert_includes cf, "**Header:** Merge mode"
    assert_includes cf, "**Header:** Away mode"
  end

  def test_reference_rendering_preserves_filesystem_paths
    compiler = SkillCompiler.new(host: "codex")
    assert_equal "$cf-plan and $cf", compiler.references("{{skill:plan}} and /cf")
    assert_equal "~/.claude/cf/bin/guard.rb", compiler.references("~/.claude/cf/bin/guard.rb")
  end

  def test_unknown_host_is_rejected
    assert_raises(ArgumentError) { SkillCompiler.new(host: "unknown") }
  end
end
