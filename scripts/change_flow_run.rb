#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative 'change_docker'
require_relative 'change_flow_compiler'
require_relative 'change_suite_render'

# Runs one declarative flow file against an ephemeral browserless Chromium
# container and prints the per-step result as JSON.
#
#   ruby scripts/change_flow_run.rb flow.yml --base-url http://127.0.0.1:3000
#   ruby scripts/change_flow_run.rb flow.yml --dump      # compile only, no run
#
# The flow file is either a bare list of steps or a mapping carrying
# `base_url`, `timeout_ms`, and `steps`. A command-line `--base-url` wins over
# the file's, so the same flow file runs against any environment without being
# edited.
#
# This is the executor `cf:qa` drives in place of hand-written Playwright: the
# steps are data, the JS is compiled from them by pure Ruby, and the same file
# run twice produces the same payload. Nothing here calls an LLM.
#
# What it prints is the redacted view. A value read from an env var reaches the
# container because a form has to be typed into, and it reaches nothing else:
# neither the printed compilation nor the printed results carry it.
module ChangeFlowRun
  module_function

  def main(argv)
    options = parse(argv)
    return usage unless options[:path]

    flow = load_flow(options[:path])
    return promote(flow, options) if options[:promote]

    compiler = ChangeFlowCompiler.new(
      flow['steps'],
      base_url: options[:base_url] || flow['base_url'],
      timeout_ms: flow['timeout_ms'] || ChangeFlowCompiler::DEFAULT_TIMEOUT_MS
    )
    puts(options[:dump] ? compiler.dump : JSON.pretty_generate(execute(compiler, options[:network])))
    0
  rescue ChangeFlowCompiler::Error => e
    warn "flow error: #{e.message}"
    1
  end

  # Renders the flow as a committed test case, so an exploratory run can end in
  # a suite file instead of a transcript. It only prints: whoever invoked it
  # shows the YAML as a diff and writes it on an explicit answer, never
  # automatically and never as a commit.
  def promote(flow, options)
    puts ChangeSuiteRender.suite_yaml(
      steps: flow['steps'], suite: options[:suite], id: options[:case_id],
      acceptance: options[:acceptance], tags: options[:tags], retries: flow['retries']
    )
    0
  rescue ChangeSuiteRender::Error => e
    warn "promote error: #{e.message}"
    1
  end

  def execute(compiler, network)
    raise 'docker is unavailable; cannot run a browser flow' unless ChangeDocker.available?

    ChangeDocker.with_network(network) do |net|
      ChangeDocker.with_browserless(network: net.name) do |session|
        session.run_function(compiler.function_module)
      end
    end
  end

  def load_flow(path)
    raw = YAML.safe_load_file(path, permitted_classes: [], aliases: true)
    return { 'steps' => raw } if raw.is_a?(Array)
    raise ChangeFlowCompiler::Error, "#{path} carries no steps:" unless raw.is_a?(Hash) && raw['steps']

    raw
  end

  def parse(argv)
    options = { path: nil, base_url: nil, network: nil, dump: false, promote: false,
                suite: nil, case_id: nil, acceptance: nil, tags: [] }
    until argv.empty?
      arg = argv.shift
      case arg
      when '--base-url' then options[:base_url] = argv.shift
      when '--network' then options[:network] = argv.shift
      when '--dump' then options[:dump] = true
      when '--promote' then options[:promote] = true
      when '--suite' then options[:suite] = argv.shift
      when '--case-id' then options[:case_id] = argv.shift
      when '--acceptance' then options[:acceptance] = argv.shift
      when '--tags' then options[:tags] = argv.shift.to_s.split(',')
      else options[:path] ||= arg
      end
    end
    options
  end

  def usage
    warn 'usage: change_flow_run.rb <flow.yml> [--base-url URL] [--network NAME] [--dump]'
    warn '       change_flow_run.rb <flow.yml> --promote --suite NAME --case-id ID ' \
         '--acceptance TEXT [--tags a,b]'
    2
  end
end

exit(ChangeFlowRun.main(ARGV)) if __FILE__ == $PROGRAM_NAME
