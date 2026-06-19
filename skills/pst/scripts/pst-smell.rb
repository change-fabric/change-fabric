#!/usr/bin/env ruby
# frozen_string_literal: true
# pst-smell.rb -- determine whether a Fowler maintainability smell pass is needed.
#
# Usage:
#   pst-smell.rb [--diff-filter <paths>]   check staged/unstaged diff
#   pst-smell.rb --files <f1> <f2> ...     check explicit file list
#
# Exit 0 always. Prints either:
#   "smell pass: required -- <N> code file(s) changed"
#   "smell pass: skipped -- docs/config/lockfiles only"

DOCS_PATTERNS = %w[
  .md .txt .rst .adoc .rdoc
  package-lock.json pnpm-lock.yaml yarn.lock Gemfile.lock
  .env .env.example
].freeze

CODE_EXTENSIONS = %w[
  .rb .js .ts .jsx .tsx .py .go .java .kt .swift .rs .c .cpp .h
  .sh .bash .zsh .fish .ps1 .lua .ex .exs .erl .hs .ml .clj .scala
  .tf .hcl .yaml .yml .json .toml
].freeze

def code_file?(path)
  ext = File.extname(path).downcase
  # YAML/JSON/TOML are code if they are not lockfiles
  return false if DOCS_PATTERNS.any? { |p| path.end_with?(p) }
  CODE_EXTENSIONS.include?(ext)
end

files = if ARGV.include?('--files')
  ARGV[ARGV.index('--files') + 1..]
else
  `git diff --name-only HEAD 2>/dev/null`.split("\n") +
  `git diff --name-only --cached 2>/dev/null`.split("\n")
end

code_files = files.uniq.select { |f| code_file?(f) }

if code_files.empty?
  puts 'smell pass: skipped -- docs/config/lockfiles only'
else
  puts "smell pass: required -- #{code_files.size} code file(s) changed"
  code_files.each { |f| puts "  #{f}" }
end
