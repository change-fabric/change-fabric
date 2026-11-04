# frozen_string_literal: true

require 'yaml'
require_relative 'skill_registry'

# Host syntax is a rendering concern. Workflow tokens are explicit; legacy
# slash references remain supported while older workflow prose is migrated.
class SkillCompiler
  HOSTS = %w[claude codex copilot opencode pi].freeze
  REFERENCE = /\{\{skill:([a-z][a-z0-9-]*)\}\}/
  LEGACY_REFERENCE = %r{(?<![\w./-])/cf(?::([a-z][a-z0-9-]*))?(?![\w/:-])}

  def initialize(host:, workflows: File.expand_path('../workflows/modes', __dir__))
    raise ArgumentError, "unknown host: #{host}" unless HOSTS.include?(host)

    @host = host
    @workflows = workflows
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
    text.gsub(REFERENCE) { invocation(Regexp.last_match(1)) }
        .gsub(LEGACY_REFERENCE) { invocation(Regexp.last_match(1) || 'cf') }
  end

  def compile(source)
    front, body = SkillRegistry::Frontmatter.split(source)
    meta = YAML.safe_load(front)
    raise ArgumentError, 'skill needs name and description' unless meta.is_a?(Hash) && meta['name'] && meta['description']

    id = meta.fetch('name').sub(/\Acf[:-]/, '')
    workflow = File.join(@workflows, "#{id}.md")
    body = File.read(workflow) if File.file?(workflow)
    meta = { 'name' => portable(meta['name']), 'description' => meta['description'] } unless @host == 'claude'
    "---\n#{YAML.dump(meta).sub(/\A---\n/, '')}---\n\n#{host_contract}\n\n#{references(body)}"
  end

  private

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
