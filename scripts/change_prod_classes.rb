#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'optparse'
require_relative 'change_prod_envelope'

# Op classes for the bounded prod runner. A class says what kind of one-way door
# an op walks through. It drives the doctor report, the notify text and the
# linkage to `change_policy.one_way_doors`; it never decides whether approval is
# needed: every class, routine included, runs through the runner with both
# approval factors (passkey with user verification, and TOTP).
#
#   change_prod_classes.rb report --config FILE [--repo PATH --base REF --head REF]
#
# Pure except the optional git diff in the CLI. Without `one_way_doors` in the
# policy, linkage is a no-op and the report says so.
module ChangeProdClasses
  DOOR_CLASSES = %w[destructive_data contracts_and_auth money_and_sends gate_config].freeze
  CLASSES = (DOOR_CLASSES + %w[routine]).freeze

  NOTES = {
    'destructive_data' => 'destroys or rewrites stored data; the snapshot and PITR window are the only way back',
    'contracts_and_auth' => 'changes a contract or credential others rely on; clients and sessions may break and issued tokens stay out',
    'money_and_sends' => 'moves money or sends messages; a backup does not undo external effects, so the op verify must check them',
    'gate_config' => 'changes a control that guards other changes; check who it lets through',
    'routine' => 'routine, bounded and reversible by redeploy; it still needs both approval factors'
  }.freeze

  module_function

  def approval_required?(klass)
    raise ChangeProdEnvelope::Invalid, "unknown op class #{klass.inspect}" unless CLASSES.include?(klass)

    true
  end

  # [{op:, class:, given:}] for every declared op, class nil when missing or unknown.
  def operations(config)
    ops = config.is_a?(Hash) ? config.dig('change_config', 'operations') : nil
    return [] unless ops.is_a?(Hash)

    ops.map do |name, definition|
      klass = definition.is_a?(Hash) ? definition['class'] : nil
      { op: name.to_s, class: CLASSES.include?(klass) ? klass : nil, given: klass }
    end
  end

  def errors(config)
    operations(config).reject { |entry| entry[:class] }.map do |entry|
      "op #{entry[:op]} has #{entry[:given].nil? ? 'no class' : "unknown class #{entry[:given].inspect}"}; use one of #{CLASSES.join(', ')}"
    end
  end

  # The text a human sees beside an approval request or a notification; nil for
  # an op with no valid class (doctor reports that).
  def notify_text(envelope, config)
    entry = operations(config).find { |op| op[:op] == envelope['op'] }
    klass = entry && entry[:class]
    return unless klass

    "#{envelope['op']} on #{envelope['environment']} is class #{klass}: #{NOTES.fetch(klass)}. Needs passkey and TOTP."
  end

  def doors(config)
    declared = config.is_a?(Hash) ? config.dig('change_policy', 'one_way_doors') : nil
    declared.is_a?(Hash) ? declared : nil
  end

  # Changed paths a door class's `paths` globs match, per op of that class. nil
  # when the policy declares no one_way_doors (a no-op); routine ops never link.
  def linkage(config, changed_paths)
    declared = doors(config)
    return unless declared

    operations(config).select { |entry| DOOR_CLASSES.include?(entry[:class]) }.filter_map do |entry|
      patterns = door_paths(declared[entry[:class]])
      files = changed_paths.select { |path| patterns.any? { |pattern| match?(pattern, path) } }
      { op: entry[:op], class: entry[:class], files: files } unless files.empty?
    end
  end

  def door_paths(door)
    list = door.is_a?(Hash) ? door['paths'] : nil
    list.is_a?(Array) ? list.grep(String) : []
  end

  # A trailing /** is every descendant at any depth; otherwise File.fnmatch with
  # ** crossing directories, as the one-way-door classifier reads globs.
  def match?(pattern, path)
    return path.start_with?(pattern.delete_suffix('**')) if pattern.end_with?('/**')

    File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
  end

  # Doctor lines. Silent when no op is declared. `changed` (paths) adds the
  # per-op linkage report when the policy declares doors.
  def report(config, changed: nil)
    entries = operations(config)
    return [] if entries.empty?

    lines = CLASSES.filter_map do |klass|
      names = entries.select { |entry| entry[:class] == klass }.map { |entry| entry[:op] }
      "prod: #{klass}: #{names.join(', ')}" unless names.empty?
    end
    lines.concat(errors(config).map { |message| "error: #{message}" })
    lines << 'prod: every class needs passkey and TOTP approval'
    lines.concat(linkage_lines(config, changed))
  end

  def linkage_lines(config, changed)
    return [ 'prod: change_policy.one_way_doors is not declared; op classes are not linked to PR paths' ] unless doors(config)
    return [] unless changed

    hits = linkage(config, changed)
    return [ 'prod: no changed path matches an op class door' ] if hits.empty?

    hits.map { |hit| "prod: changed #{hit[:files].join(', ')} touches the #{hit[:class]} door of op #{hit[:op]}" }
  end

  def changed_paths(repo, base, head)
    out, status = Open3.capture2e('git', '-C', repo, 'diff', '--name-only', '-z', "#{base}...#{head}")
    raise ChangeProdEnvelope::Invalid, "cannot diff #{base}...#{head}" unless status.success?

    out.split("\0")
  end

  def run(argv, stdout: $stdout, stderr: $stderr)
    opts = { repo: '.' }
    OptionParser.new do |o|
      o.on('--config PATH') { |v| opts[:config] = v }
      o.on('--repo PATH') { |v| opts[:repo] = v }
      o.on('--base REF') { |v| opts[:base] = v }
      o.on('--head REF') { |v| opts[:head] = v }
    end.parse!(argv)
    return usage(stderr) unless argv.shift == 'report' && opts[:config]

    config = ChangeProdEnvelope.load_config(opts[:config])
    changed = opts[:base] && opts[:head] ? changed_paths(opts[:repo], opts[:base], opts[:head]) : nil
    stdout.puts report(config, changed: changed)
    errors(config).empty? ? 0 : 1
  rescue OptionParser::ParseError, ChangeProdEnvelope::Invalid => e
    stderr.puts "[cf-prod] #{e.message}"
    1
  end

  def usage(stderr)
    stderr.puts 'usage: change_prod_classes.rb report --config FILE [--repo PATH --base REF --head REF]'
    2
  end
end

exit(ChangeProdClasses.run(ARGV)) if __FILE__ == $PROGRAM_NAME
