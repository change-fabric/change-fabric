# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../scripts/skill_compiler"
require_relative "../scripts/review_prompt"

class SkillCompilerTest < Minitest::Test
  def test_mode_contract_is_shared_by_all_hosts
    source = File.read(File.expand_path("../skills/merge-ready/SKILL.md", __dir__))
    (SkillCompiler::HOSTS - [ "claude" ]).each do |host|
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

  CLAUDE_ROLES = { "orchestrator" => "opus", "worker" => "sonnet", "author" => "opus", "critic" => "opus", "classifier" => "haiku" }.freeze

  def claude = SkillCompiler.new(host: "claude", roles: CLAUDE_ROLES)

  def neutral(host = "codex") = SkillCompiler.new(host: host, roles: nil)

  # render_model_prose

  def test_prose_claude_renders_the_model_name
    assert_equal "research on sonnet, judge on opus", claude.render_model_prose("research on {{model:worker}}, judge on {{model:critic}}")
  end

  def test_prose_without_a_host_entry_renders_the_neutral_phrase
    assert_equal "use the host's worker-tier model", neutral.render_model_prose("use {{model:worker}}")
  end

  def test_prose_unknown_role_raises
    assert_raises(ArgumentError) { claude.render_model_prose("{{model:planner}}") }
  end

  def test_references_renders_model_tokens_beside_skill_tokens
    assert_equal "$cf-plan on the host's author-tier model", neutral.references("{{skill:plan}} on {{model:author}}")
  end

  # render_model_js

  def test_js_claude_renders_a_json_property
    assert_equal %(agent({ prompt: p, model: "sonnet" })), claude.render_model_js("agent({ prompt: p, model: {{model-js:worker}} })")
  end

  def test_js_without_a_host_entry_deletes_the_property_in_first_middle_and_last_position
    source = <<~JS
      const first = { model: {{model-js:worker}}, a: 1, b: 2 };
      const middle = { a: 1, model: {{model-js:worker}}, b: 2 };
      const last = { a: 1, b: 2, model: {{model-js:worker}} };
      const only = { model: {{model-js:worker}} };
      const spread = {
        a: 1,
        model: {{model-js:critic}},
        b: 2,
      };
      const tail = {
        a: 1,
        model: {{model-js:critic}}
      };
      const head = {
        model: {{model-js:critic}},
        a: 1,
      };
    JS
    rendered = neutral.render_model_js(source)
    refute_includes rendered, "model"
    assert_includes rendered, "const first = { a: 1, b: 2 };"
    assert_includes rendered, "const middle = { a: 1, b: 2 };"
    assert_includes rendered, "const last = { a: 1, b: 2 };"
    assert_includes rendered, "const spread = {\n  a: 1,\n  b: 2,\n};"
    assert_includes rendered, "const tail = {\n  a: 1\n};"
    assert_includes rendered, "const head = {\n  a: 1,\n};"
    assert_node_parses(rendered)
  end

  def test_js_misplaced_token_raises
    assert_raises(ArgumentError) { claude.render_model_js("const m = {{model-js:worker}};") }
    assert_raises(ArgumentError) { claude.render_model_js("agent({ 'model': {{model-js:worker}} })") }
  end

  def test_js_prose_token_raises
    assert_raises(ArgumentError) { claude.render_model_js("// uses {{model:worker}}") }
  end

  def test_js_unknown_role_raises
    assert_raises(ArgumentError) { claude.render_model_js("a({ model: {{model-js:planner}} })") }
  end

  def test_js_emits_json_encoding_even_for_a_value_that_bypasses_validation
    nasty = "o\"pus\\\nx"
    compiler = SkillCompiler.new(host: "claude", roles: CLAUDE_ROLES.merge("worker" => nasty))
    rendered = compiler.render_model_js("const a = { model: {{model-js:worker}} };")
    assert_node_parses(rendered)
    assert_equal nasty, JSON.parse(rendered[/model: (".*")/, 1])
  end

  # rewrite_reviewer

  def test_reviewer_claude_emits_the_full_agent_expression_with_the_classifier_model
    text = claude.rewrite_reviewer("Launch the review now:\n#{ReviewPrompt::REVIEWER},\ngiving it a task")
    assert_includes text, %(Agent(subagent_type: "general-purpose", model: "haiku"),)
    refute_includes text, "{{model"
  end

  def test_reviewer_follows_the_resolved_classifier_model
    compiler = SkillCompiler.new(host: "claude", roles: CLAUDE_ROLES.merge("classifier" => "sonnet"))
    assert_includes compiler.rewrite_reviewer(ReviewPrompt::REVIEWER), 'model: "sonnet"'
  end

  def test_reviewer_other_hosts_emit_the_fallback_sentence_and_no_partial_expression
    (SkillCompiler::HOSTS - [ "claude" ]).each do |host|
      text = SkillCompiler.new(host: host, roles: CLAUDE_ROLES).rewrite_reviewer("x\n#{ReviewPrompt::REVIEWER},\ny")
      assert_includes text, "Use the host-native reviewer or review the files directly when delegation is unavailable,", host
      refute_match(/Agent\(|subagent_type|\{\{model/, text, host)
    end
  end

  def test_reviewer_claude_without_a_snapshot_entry_falls_back_too
    refute_includes neutral("claude").rewrite_reviewer(ReviewPrompt::REVIEWER), "Agent("
  end

  def test_reviewer_unknown_role_raises
    assert_raises(ArgumentError) { claude.rewrite_reviewer("x", role: "planner") }
  end

  private

  def assert_node_parses(source)
    skip "node not installed" unless system("node --version", out: File::NULL, err: File::NULL)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "fixture.js")
      File.write(file, source)
      _out, err, status = Open3.capture3("node", "--check", file)
      assert status.success?, "node --check failed: #{err}"
    end
  end
end
