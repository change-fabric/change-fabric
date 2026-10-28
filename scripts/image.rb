# frozen_string_literal: true

require 'fileutils'
require 'optparse'
require_relative 'prototype_imagegen'
require_relative 'walkthrough_env'

# cf:image: a thin paid command over PrototypeImagegen (gpt-image-2 by default,
# CF_IMAGE_MODEL to override). It owns only the CLI: argument handling, the
# cost ceiling, and the output copy. Generation, the content-key cache, and the
# edits multipart live in PrototypeImagegen so there is one implementation.
module Image
  DEFAULT_CEILING_USD = 1.0
  DEFAULT_SIZE = '1024x1024'
  DEFAULT_QUALITY = PrototypeImagegen::QUALITY_DRAFT
  USAGE = 'usage: image.rb "<prompt>" | --prompt-file PATH [--size WxH] [--quality low|medium|high] ' \
          '[--ref PNG]... [--edit PNG [--mask PNG]] [--out PATH] [--max-usd N] [--cache DIR] [--estimate-only]'

  class UsageError < StandardError; end
  class CeilingError < StandardError; end

  # Run returns the exit code: 0 ok, 1 a named failure, 2 usage (as elevenlabs.rb).
  module Cli
    module_function

    def run(argv, out: $stdout, http: nil)
      opts = parse(argv.dup)
      WalkthroughEnv.load_secrets
      generate(opts, out, http)
      0
    rescue UsageError, OptionParser::ParseError => e
      out.puts("error: #{e.message}", USAGE)
      2
    rescue CeilingError, PrototypeImagegen::RequestError, WalkthroughEnv::MissingKeyError, SystemCallError => e
      out.puts("error: #{e.message}")
      1
    end

    def parse(args)
      opts = { size: DEFAULT_SIZE, quality: DEFAULT_QUALITY, refs: [], max_usd: DEFAULT_CEILING_USD, cache: '.cache' }
      OptionParser.new do |o|
        o.on('--prompt-file PATH') { |v| opts[:prompt_file] = v }
        o.on('--size WxH') { |v| opts[:size] = v }
        o.on('--quality Q') { |v| opts[:quality] = v }
        o.on('--ref PNG') { |v| opts[:refs] << v }
        o.on('--edit PNG') { |v| opts[:edit] = v }
        o.on('--mask PNG') { |v| opts[:mask] = v }
        o.on('--out PATH') { |v| opts[:out] = v }
        o.on('--max-usd N', Float) { |v| opts[:max_usd] = v }
        o.on('--cache DIR') { |v| opts[:cache] = v }
        o.on('--estimate-only') { opts[:estimate_only] = true }
      end.parse!(args)
      opts[:prompt] = prompt_from(opts, args)
      validate!(opts)
      opts
    end

    def prompt_from(opts, positional)
      raise UsageError, 'give a prompt or --prompt-file, not both' if opts[:prompt_file] && !positional.empty?
      raise UsageError, 'a prompt or --prompt-file is required' if opts[:prompt_file].nil? && positional.empty?

      (opts[:prompt_file] ? File.read(opts[:prompt_file]) : positional.join(' ')).strip
    end

    def validate!(opts)
      raise UsageError, '--mask needs --edit' if opts[:mask] && !opts[:edit]
      raise UsageError, 'the prompt is empty' if opts[:prompt].empty?
      raise UsageError, "--quality must be one of #{PrototypeImagegen::PRICE.keys.join(', ')}" unless PrototypeImagegen::PRICE.key?(opts[:quality])
      raise UsageError, '--size must look like 1024x1024' unless opts[:size].match?(/\A\d+x\d+\z/)
    end

    def generate(opts, out, http)
      [ *opts[:refs], opts[:edit], opts[:mask] ].compact.each { |f| raise Errno::ENOENT, f unless File.file?(f) }
      args = opts.slice(:size, :quality, :refs, :edit, :mask).merge(prompt: opts[:prompt])
      cached = File.file?(WalkthroughCache.path(opts[:cache], :images, PrototypeImagegen.asset_key(**args), 'png'))
      usd = announce(opts, out, cached)
      raise CeilingError, "$#{format('%.2f', usd)} would pass the $#{format('%.2f', opts[:max_usd])} ceiling" if usd > opts[:max_usd] + 1e-9
      return if opts[:estimate_only]

      path = PrototypeImagegen.generate(**args, cache_root: opts[:cache], http: http)
      path = copy_out(path, opts[:out]) if opts[:out]
      out.puts("image: #{path}")
    end

    # Prints the estimate before any paid call and returns the USD it will cost.
    def announce(opts, out, cached)
      est = PrototypeImagegen.estimate([ { quality: opts[:quality] } ])
      usd = cached ? 0.0 : est[:usd]
      what = cached ? '1 image (cached)' : est[:line]
      out.puts("image estimate: #{what}, $#{format('%.2f', usd)} to spend")
      usd
    end

    def copy_out(path, dest)
      FileUtils.mkdir_p(File.dirname(File.expand_path(dest)))
      FileUtils.cp(path, dest)
      dest
    end
  end
end

exit(Image::Cli.run(ARGV)) if __FILE__ == $PROGRAM_NAME
