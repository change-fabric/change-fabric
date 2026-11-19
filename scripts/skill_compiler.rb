# frozen_string_literal: true

require 'yaml'
require 'json'
require_relative 'skill_registry'
require_relative 'model_roles'
require_relative 'review_prompt'

# Host syntax is a rendering concern. Workflow tokens are explicit; legacy
# slash references remain supported while older workflow prose is migrated.
class SkillCompiler
  HOSTS = %w[claude codex copilot opencode pi].freeze
  REFERENCE = /\{\{skill:([a-z][a-z0-9-]*)\}\}/
  MODEL_PROSE = /\{\{model:([a-z]+)\}\}/
  MODEL_JS_TOKEN = /\{\{model-js:/
  MODEL_JS_PROPERTY = /model:[ \t]*\{\{model-js:([a-z]+)\}\}/
  # Hosts with an Agent tool that takes a model argument.
  AGENT_HOSTS = %w[claude].freeze
  REVIEWER_FALLBACK = 'Use the host-native reviewer or review the files directly when delegation is unavailable'
  LEGACY_REFERENCE = %r{(?<![\w./-])/cf(?::([a-z][a-z0-9-]*))?(?![\w/:-])}

  # roles is the resolved {role => model} table for this host. Install passes
  # the table it is about to snapshot; runtime callers omit it and read the
  # installed snapshot (else the repo map). nil means the host has no entry.
  def initialize(host:, workflows: File.expand_path('../workflows/modes', __dir__), roles: :installed)
    raise ArgumentError, "unknown host: #{host}" unless HOSTS.include?(host)

    @host = host
    @workflows = workflows
    @roles = roles
  end

  def invocation(id)
    name = id == 'cf' ? 'cf' : "cf-#{id}"
    case @host
    when 'claude' then id == 'cf' ? '/cf' : "/cf:#{id}"
    when 'codex' then "$#{name}"
    when 'pi' then "/skill:#{name}"
    else "the #{name} skill"
    end
  end

  def references(text)
    render_model_prose(text).gsub(REFERENCE) { invocation(Regexp.last_match(1)) }
                            .gsub(LEGACY_REFERENCE) { invocation(Regexp.last_match(1) || 'cf') }
  end

  # {{model:<role>}} in prose: the model name, or a host-neutral phrase when the
  # host has no entry in the role map.
  def render_model_prose(text)
    text.gsub(MODEL_PROSE) do
      role = Regexp.last_match(1)
      ModelRoles.check_role!(role)
      model_for(role) || "the host's #{role}-tier model"
    end
  end

  # Only the property form `model: {{model-js:<role>}}` in .js files. With a
  # model it emits JSON-encoded output; without one it deletes the whole
  # property (and one adjacent comma) so the agent inherits. Any other use of
  # the token, or a prose token in JS, raises.
  def render_model_js(text)
    raise ArgumentError, 'a {{model:<role>}} prose token does not belong in a .js file; use model: {{model-js:<role>}}' if text.match?(MODEL_PROSE)

    out = +''
    rest = text
    while (match = MODEL_JS_PROPERTY.match(rest))
      role = match[1]
      ModelRoles.check_role!(role)
      emitted, rest = js_property(rest[0...match.begin(0)], rest[match.end(0)..], role)
      out << emitted
    end
    out << rest
    raise ArgumentError, 'misplaced {{model-js:<role>}} token; it is valid only as `model: {{model-js:<role>}}`' if out.match?(MODEL_JS_TOKEN)

    out
  end

  # The whole REVIEWER Agent expression, role-keyed per host. Hosts with an
  # Agent tool and a model for the role get the full expression; every other
  # host gets one fallback sentence, never a partial expression.
  def rewrite_reviewer(text, role: 'classifier')
    ModelRoles.check_role!(role)
    model = AGENT_HOSTS.include?(@host) ? model_for(role) : nil
    replacement = model ? %(Agent(subagent_type: "general-purpose", model: #{JSON.generate(model)})) : REVIEWER_FALLBACK
    text.gsub(ReviewPrompt::REVIEWER) { replacement }
  end

  def compile(source)
    front, body = SkillRegistry::Frontmatter.split(source)
    meta = YAML.safe_load(front)
    raise ArgumentError, 'skill needs name and description' unless meta.is_a?(Hash) && meta['name'] && meta['description']

    # Claude has the installed adapter (hooks keyed to exact question headers
    # and skill loads), so it keeps the native body; other hosts get the
    # adapter-free shared contract.
    return "---\n#{YAML.dump(meta).sub(/\A---\n/, '')}---\n#{references(body)}" if @host == 'claude'

    id = meta.fetch('name').sub(/\Acf[:-]/, '')
    workflow = File.join(@workflows, "#{id}.md")
    body = File.read(workflow) if File.file?(workflow)
    meta = { 'name' => portable(meta['name']), 'description' => meta['description'] }
    "---\n#{YAML.dump(meta).sub(/\A---\n/, '')}---\n\n#{host_contract}\n\n#{references(body)}"
  end

  private

  def model_for(role)
    roles = @roles == :installed ? ModelRoles.installed_or_repo_roles(@host) : @roles
    roles&.[](role)
  end

  # Returns [text to emit for the span before and including the property, the
  # tail still to scan].
  def js_property(before, after, role)
    model = model_for(role)
    return [ "#{before}model: #{JSON.generate(model)}", after ] unless model.nil?

    if (comma = after.match(/\A[ \t]*,/))
      after = after[comma.end(0)..]
      if before.match?(/(\A|\n)[ \t]*\z/) && after.match?(/\A[ \t]*\n/)
        [ before.sub(/[ \t]*\z/, ''), after.sub(/\A[ \t]*\n/, '') ]
      else
        [ before, after.sub(/\A[ \t]+/, '') ]
      end
    else
      [ before.sub(/,[ \t\n]*\z/, ''), after ]
    end
  end

  def portable(name) = name.downcase.gsub(/[^a-z0-9]+/, '-').sub(/-\z/, '')

  def host_contract
    <<~TEXT.strip
      Host: #{@host}. Use this host's native question, execution, and delegation tools.
      Claude tool names and hook paths in older references describe the Claude adapter;
      they do not establish hooks or state in this host. Only an installed adapter's
      runtime response proves persistence. Otherwise keep mode intent in conversation
      and compaction summaries. Never claim command guards or lifecycle support from
      skill discovery alone. Host permissions and explicit user instructions take precedence.
    TEXT
  end
end
