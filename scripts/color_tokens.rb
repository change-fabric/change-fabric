#!/usr/bin/env ruby
# frozen_string_literal: true

require 'set'

# Everything about the cf:color token file that is not CSS parsing: where it
# lives, and the fixed pairing rule the checker grades. Parsing, the
# cascade, and value resolution all live in the browser now (color_browser.rb);
# this module only ports the pieces of the old hand-written CSS parser worth
# keeping.
module ColorTokens
  # Conventional token-file locations, relative to the scan root, in order.
  PATHS = %w[
    app/globals.css
    src/app/globals.css
    app/styles/tokens.css
    src/styles/tokens.css
    styles/tokens.css
    src/styles/globals.css
    styles/globals.css
    src/index.css
    app/assets/stylesheets/tokens.css
    tokens.css
  ].freeze

  # The foreground suffixes of the fixed pair rule: "--x-<suffix>" pairs with
  # "--x" when declared, else with "--background".
  FG_SUFFIXES = %w[text fg foreground ink].freeze
  FG_NAME = /\A--(.+)-(?:#{FG_SUFFIXES.join('|')})\z/.freeze
  PAGE_BACKGROUND = '--background'
  ERROR_TOKEN = '--error'
  TARGET = 4

  Error = Data.define(:line, :message)

  module_function

  # The token file path, or an Error naming every candidate when zero or
  # several conventional paths exist. An override is expanded against the
  # current directory (normal CLI convention) and must be a readable file.
  def locate(root, override)
    return locate_override(override) if override

    found = PATHS.map { |rel| File.join(root, rel) }.select { |p| File.file?(p) }
    return found.first if found.size == 1

    if found.empty?
      Error.new(line: nil, message: "no token file found; looked for #{PATHS.join(', ')} (or pass --tokens)")
    else
      Error.new(line: nil, message: "several token files found: #{found.join(', ')}; pass --tokens to pick one")
    end
  end

  def locate_override(override)
    path = File.expand_path(override)
    return Error.new(line: nil, message: "--tokens #{override}: no such file") unless File.exist?(path)
    return Error.new(line: nil, message: "--tokens #{override}: is a directory, not a file") if File.directory?(path)
    return Error.new(line: nil, message: "--tokens #{override}: is not readable") unless File.readable?(path)

    path
  end

  # [[fg, bg]] for every "--x-<suffix>" name in the given name collection
  # (anything that responds to each_key or is itself enumerable of names),
  # per the fixed pair rule: "--x-<suffix>" pairs with "--x" when names
  # includes it, else with "--background".
  def pairs(names)
    name_set = names.respond_to?(:each_key) ? names.each_key.to_a : names.to_a
    set = name_set.to_set
    name_set.filter_map do |name|
      m = FG_NAME.match(name)
      next unless m

      surface = "--#{m[1]}"
      [ name, set.include?(surface) ? surface : PAGE_BACKGROUND ]
    end
  end
end
