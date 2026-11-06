#!/usr/bin/env ruby
# frozen_string_literal: true

# Records where a project's API keys come from in ~/.claude/cf/secrets.yml.
#   set --project-key K --source PATH|env [--provider P] [--env-var NAME[,ALIAS...]]
#   status
#   default --source PATH
# Exit 0 ok, 2 usage or setup error. Never prints a key value.

require 'fileutils'
require 'open3'
require 'optparse'
require 'tempfile'
require 'yaml'
require_relative 'cf_secrets'

# The enrollment CLI. Validates a source, then writes the store atomically.
class CfSecretsEnroll
  class Failure < StandardError; end

  def initialize(argv, out: $stdout, err: $stderr, home: Dir.home)
    @argv = argv.dup
    @out = out
    @err = err
    @path = CfSecrets.store_path(home)
  end

  def run
    command = @argv.shift
    case command
    when 'set' then set(parse(%i[project_key source provider env_var]))
    when 'default' then default(parse(%i[source env_var]))
    when 'status' then status
    else raise Failure, 'usage: cf_secrets_enroll.rb set|status|default'
    end
    0
  rescue Failure, OptionParser::ParseError => e
    @err.puts("cf_secrets_enroll: #{e.message}")
    2
  end

  private

  def parse(allowed)
    opts = {}
    OptionParser.new do |o|
      allowed.each { |k| o.on("--#{k.to_s.tr('_', '-')} VALUE") { |v| opts[k] = v } }
    end.parse!(@argv)
    opts
  end

  def set(opts)
    key = opts[:project_key] or raise Failure, '--project-key is required'
    source = validate_source(opts[:source], opts[:env_var])
    update_store do |store|
      entry = ((store['projects'] ||= {})[key] ||= {})
      if opts[:provider]
        (entry['providers'] ||= {})[opts[:provider]] = source
      else
        entry['env_file'] = source
      end
    end
    @out.puts("recorded #{key}: #{opts[:provider] || 'env_file'} -> #{source}")
  end

  def default(opts)
    source = validate_source(opts[:source], opts[:env_var])
    raise Failure, 'default must be an env file path, not env' if source == CfSecrets::ENV_ONLY

    update_store { |store| store['default'] = source }
    @out.puts("recorded default -> #{source}")
  end

  def status
    store = read_store
    @out.puts("default: #{store['default'] || '(none)'}")
    (store['projects'] || {}).each do |key, entry|
      next unless entry.is_a?(Hash)

      @out.puts("#{key}: #{entry['env_file'] || '(none)'}")
      (entry['providers'] || {}).each { |p, src| @out.puts("  #{p}: #{src}") }
    end
  end

  def validate_source(source, env_var)
    raise Failure, '--source is required' if source.nil? || source.empty?
    return CfSecrets::ENV_ONLY if source == CfSecrets::ENV_ONLY

    full = File.expand_path(source)
    raise Failure, "no such file: #{full}" unless File.file?(full)
    # env_var may list accepted aliases (ELEVEN_LABS_API_KEY,ELEVENLABS_API_KEY);
    # any one of them in the file is enough, as at resolve time.
    if env_var && (env_var.split(',') & names(full)).empty?
      raise Failure, "#{full} has no #{env_var.tr(',', '/')}= line"
    end

    warn_if_tracked(full)
    full
  end

  def names(full)
    File.foreach(full).filter_map { |line| CfSecrets.parse_line(line)&.first }
  rescue SystemCallError
    []
  end

  def warn_if_tracked(full)
    dir = File.dirname(full)
    inside, = Open3.capture2e('git', '-C', dir, 'rev-parse', '--is-inside-work-tree')
    return unless inside.strip == 'true'

    _, st = Open3.capture2e('git', '-C', dir, 'check-ignore', '-q', full)
    @err.puts("warning: #{full} is inside a git work tree and not gitignored") unless st.success?
  rescue SystemCallError
    nil
  end

  # Holds an exclusive lock across the read and the write, so two concurrent
  # enrollments cannot both read the old store and drop each other's change.
  def update_store
    FileUtils.mkdir_p(File.dirname(@path))
    File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      store = read_store
      yield store
      write_store(store)
    end
  end

  def read_store
    return {} unless File.file?(@path)

    data = YAML.safe_load_file(@path)
    return {} if data.nil?
    raise Failure, "#{@path} is not a mapping; refusing to overwrite" unless data.is_a?(Hash)

    data
  rescue Psych::Exception
    raise Failure, "#{@path} is not valid YAML; refusing to overwrite"
  end

  def write_store(store)
    tmp = Tempfile.create([ 'secrets', '.yml' ], File.dirname(@path))
    tmp.write(YAML.dump(store))
    tmp.close
    File.chmod(0o600, tmp.path)
    File.rename(tmp.path, @path)
  end
end

exit CfSecretsEnroll.new(ARGV).run if $PROGRAM_NAME == __FILE__
