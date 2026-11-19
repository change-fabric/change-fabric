# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "../../scripts/skill_compiler"
require_relative "../../scripts/model_roles"

# Workflow scripts carry `model: {{model-js:<role>}}`, which is a syntax error
# until the skill compiler renders it. Tests that run a workflow.js under node
# call RenderedWorkflow.path(source) and run the returned file instead.
#
# It renders for host claude against the repo role map only (no env overrides,
# no user file, no install snapshot), so CI and a local machine agree.
module RenderedWorkflow
  module_function

  # Absolute path of the rendered copy of the workflow script at source_path.
  def path(source_path)
    cache[source_path] ||= begin
      out = File.join(dir, source_path.delete_prefix("#{File.expand_path('../..', __dir__)}/").tr("/", "_"))
      File.write(out, compiler.render_model_js(File.read(source_path)))
      out
    end
  end

  def compiler
    @compiler ||= begin
      roles = ModelRoles.table(host: "claude", env: {}, user_file: File::NULL)
      SkillCompiler.new(host: "claude", roles: roles)
    end
  end

  def cache = (@cache ||= {})

  def dir
    @dir ||= Dir.mktmpdir("rendered-workflow").tap { |made| at_exit { FileUtils.remove_entry(made, true) } }
  end
end
