#!/usr/bin/env ruby
# frozen_string_literal: true
# pst-ledger.rb -- session-scoped task ledger for multi-repo orchestration (rule 22).
#
# Usage:
#   pst-ledger.rb init
#   pst-ledger.rb register <id> [--repo <path>] [--worktree <path>] [--intent <str>] [--label <str>] [--agent <str>]
#   pst-ledger.rb update <id> [--status <s>] [--summary <str>]
#   pst-ledger.rb running <id>
#   pst-ledger.rb done <id> [--summary <str>]
#   pst-ledger.rb fail <id> [--summary <str>]
#   pst-ledger.rb list
#   pst-ledger.rb dump
#   pst-ledger.rb context
#   pst-ledger.rb clear

require 'json'
require 'fileutils'
require_relative File.join(__dir__, 'hooks', 'pst_common')

NOW = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
INTENT_COL_WIDTH = 60

# Resolve session id without hanging on stdin when not in a hook context.
# When stdin is a tty, or CLAUDE_SESSION_ID is already in the environment,
# skip reading stdin entirely and return the env value.
def resolve_sid
  if $stdin.isatty || ENV['CLAUDE_SESSION_ID']
    return ENV['CLAUDE_SESSION_ID'].to_s
  end
  Pst.session_id
end

# Parse --key value pairs from ARGV; returns a hash.
def parse_flags(argv)
  flags = {}
  i = 0
  while i < argv.length
    arg = argv[i]
    if arg.start_with?('--')
      key = arg[2..]
      val = argv[i + 1]
      flags[key] = val.to_s
      i += 2
    else
      # non-flag positional tokens are collected separately via ARGV; they are not flags
      i += 1
    end
  end
  flags
end


def transition(file, id, new_status, summary: nil)
  entries = Pst.read_entries(file)
  entry = find_entry(entries, id)
  unless entry
    warn "pst-ledger: entry #{id} not found"
    exit 1
  end
  entry['status']     = new_status
  entry['updated_at'] = NOW
  entry['summary']    = summary unless summary.nil?
  save_entries(file, entries)
  puts "pst-ledger: #{id} -> #{new_status}"
end

cmd = ARGV[0]
positional = ARGV[1..].reject { |a| a.start_with?('--') }
flags = parse_flags(ARGV[1..])

sid = resolve_sid
if sid.empty? && cmd != 'help'
  warn 'pst-ledger: no session id found; is PST mode active?'
  exit 1
end

ledger_dir  = File.join(Pst::HOME, 'ledger')
ledger_file = File.join(ledger_dir, "#{sid}.json")

def save_entries(path, entries)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.pretty_generate(entries))
end

def find_entry(entries, id)
  entries.find { |e| e['id'] == id }
end

# Display projection: the columns `list` and `context` render. Both derive their
# cells from this, so adding or renaming a column is a one-place change.
def display_fields(entry)
  {
    id: entry['id'].to_s,
    status: entry['status'].to_s,
    repo: File.basename(entry['repo'].to_s),
    intent: entry['intent'].to_s
  }
end

case cmd
when 'init'
  if File.exist?(ledger_file)
    puts 'pst-ledger: already initialized'
    exit 0
  end
  FileUtils.mkdir_p(ledger_dir)
  save_entries(ledger_file, [])
  puts "pst-ledger: initialized ledger for session #{sid}"

when 'register'
  id = positional[0]
  unless id && !id.empty?
    warn 'usage: pst-ledger.rb register <id> [--repo <path>] [--worktree <path>] [--intent <str>] [--label <str>] [--agent <str>]'
    exit 1
  end
  entries = Pst.read_entries(ledger_file)
  if find_entry(entries, id)
    warn "pst-ledger: entry #{id} already exists; use update to modify it"
    exit 1
  end
  entry = {
    'id'         => id,
    'label'      => flags['label'] || id,
    'repo'       => flags['repo'] || '',
    'worktree'   => flags['worktree'] || '',
    'intent'     => flags['intent'] || '',
    'status'     => 'pending',
    'agent'      => flags['agent'] || '',
    'spawned_at' => NOW,
    'updated_at' => NOW,
    'summary'    => ''
  }
  entries << entry
  save_entries(ledger_file, entries)
  puts "pst-ledger: registered #{id}"

when 'update'
  id = positional[0]
  unless id && !id.empty?
    warn 'usage: pst-ledger.rb update <id> [--status <s>] [--summary <str>]'
    exit 1
  end
  entries = Pst.read_entries(ledger_file)
  entry = find_entry(entries, id)
  unless entry
    warn "pst-ledger: entry #{id} not found"
    exit 1
  end
  entry['status']     = flags['status']  if flags.key?('status')
  entry['summary']    = flags['summary'] if flags.key?('summary')
  entry['updated_at'] = NOW
  save_entries(ledger_file, entries)
  puts "pst-ledger: updated #{id}"

when 'running'
  transition(ledger_file, positional[0], 'running')

when 'done'
  transition(ledger_file, positional[0], 'done', summary: flags['summary'])

when 'fail'
  transition(ledger_file, positional[0], 'failed', summary: flags['summary'])

when 'list'
  entries = Pst.read_entries(ledger_file)
  if entries.empty?
    puts '(no tasks registered)'
    exit 0
  end
  rows = entries.map { |e| display_fields(e) }
  col_id     = [2, *rows.map { |r| r[:id].length }].max
  col_status = [6, *rows.map { |r| r[:status].length }].max
  col_repo   = [4, *rows.map { |r| r[:repo].length }].max
  header = "%-#{col_id}s  %-#{col_status}s  %-#{col_repo}s  %s" % %w[ID STATUS REPO INTENT]
  puts header
  puts '-' * [header.length, 80].min
  rows.each do |r|
    intent = r[:intent]
    intent = intent[0, INTENT_COL_WIDTH] + '...' if intent.length > INTENT_COL_WIDTH
    puts "%-#{col_id}s  %-#{col_status}s  %-#{col_repo}s  %s" % [r[:id], r[:status], r[:repo], intent]
  end

when 'dump'
  entries = Pst.read_entries(ledger_file)
  puts JSON.pretty_generate(entries)

when 'context'
  entries = Pst.read_entries(ledger_file)
  puts '## Active session tasks'
  puts ''
  puts '| ID | Status | Repo | Intent |'
  puts '|---|---|---|---|'
  if entries.empty?
    puts '| (none) | | | |'
  else
    entries.each do |e|
      r = display_fields(e)
      puts "| #{r[:id]} | #{r[:status]} | #{r[:repo]} | #{r[:intent]} |"
    end
  end
  puts ''
  puts 'Pass this context to any new agent so it knows what sibling work is in flight.'

when 'clear'
  FileUtils.rm_f(ledger_file)
  puts "pst-ledger: cleared ledger for session #{sid}"

else
  warn 'usage: pst-ledger.rb init | register <id> [...] | update <id> [...] | running <id> | done <id> | fail <id> | list | dump | context | clear'
  exit 1
end
