#!/usr/bin/env ruby
# frozen_string_literal: true
# Deterministic em dash utility for PST mode. Use this instead of hand-editing
# when you need to find or strip em dashes.
#
#   pst-emdash.rb check [path ...]   exit 1 if any em dash is found (stdin if no paths)
#   pst-emdash.rb prune [path ...]   replace em dashes in place (stdin -> stdout if none)
#
# Replacement is deterministic: an em dash with any surrounding whitespace becomes
# a single spaced hyphen " - ". Adjust SUB here if you prefer a comma or colon.
EM = [0x2014].pack('U')
SUB = ' - '

def prune(text)
  text.gsub(/[ \t]*#{Regexp.escape(EM)}[ \t]*/, SUB)
end

mode = ARGV.shift
paths = ARGV

case mode
when 'check'
  found = false
  if paths.empty?
    found = $stdin.read.include?(EM)
  else
    paths.each do |p|
      File.foreach(p).with_index(1) do |line, n|
        if line.include?(EM)
          found = true
          puts "#{p}:#{n}: #{line.strip}"
        end
      end
    end
  end
  exit(found ? 1 : 0)
when 'prune'
  if paths.empty?
    print prune($stdin.read)
  else
    paths.each do |p|
      original = File.read(p)
      cleaned = prune(original)
      next if cleaned == original

      File.write(p, cleaned)
      puts "pruned em dashes: #{p}"
    end
  end
else
  warn 'usage: pst-emdash.rb {check|prune} [path ...]'
  exit 2
end
