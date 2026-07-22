#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

# Splits the leading `---\n...\n---\n` YAML frontmatter off a CHANGE.md and
# returns it as a hash. CHANGE.md is the single change-fabric file: its
# frontmatter carries both `change_config:` (the mechanical target-app details)
# and `change_policy:` (the merge-gate policy), with the prose body below as the
# human governance FAQ. Both the config loader and the policy reader parse the
# same block through here so the split lives in one place.
#
# Fail-soft: a missing or malformed frontmatter yields an empty hash rather than
# raising, since the policy reader runs inside a hook and must never crash. The
# config loader layers its own stricter "no change_config block" error on top.
module ChangeFrontmatter
  PATTERN = /\A---\s*\n(.*?\n)---\s*\n/m

  module_function

  def parse(text)
    match = text.to_s.match(PATTERN)
    front = match && YAML.safe_load(match[1])
    front.is_a?(Hash) ? front : {}
  rescue Psych::SyntaxError
    {}
  end

  def parse_file(path)
    File.exist?(path) ? parse(File.read(path)) : {}
  rescue SystemCallError
    {}
  end
end
