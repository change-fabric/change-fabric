#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'
require 'uri'
require_relative 'change_config'
require_relative 'change_docker'
require_relative 'change_flow_compiler'
require_relative 'change_suite_render'
require_relative 'change_lane_browserless'

# Whether a flow opens with a persona's login, and how many steps that login
# took: each auth step's page, its fields filled in order, its submit clicked,
# and its post-submit wait, each optional only where the auth step has none.
module ChangeFlowLogin
  module_function

  def prefix_length(steps, auth)
    position = 0
    auth.steps.each do |auth_step|
      position = match_step(steps, position, auth_step)
      return 0 unless position
    end
    position
  end

  def match_step(steps, position, auth_step)
    if auth_step[:url] && !auth_step[:url].empty?
      return nil unless same_path?(value(steps[position], 'goto', 'url'), auth_step[:url])

      position += 1
    end
    auth_step[:fields].each do |field|
      return nil unless same_field?(steps[position], field)

      position += 1
    end
    if auth_step[:submit_selector]
      return nil unless value(steps[position], 'click', 'selector') == auth_step[:submit_selector]

      position += 1
      position += 1 if navigation_wait?(steps[position])
    end
    position += 1 if auth_step[:wait_for_selector] && value(steps[position], 'wait_for', 'selector') == auth_step[:wait_for_selector]
    position
  end

  # The same field typed from the same source: two personas often share one
  # login form, and only the env var (or code_source) tells them apart.
  def same_field?(step, field)
    return false unless value(step, 'fill', 'selector') == field[:selector]
    return value(step, 'fill', 'env') == field[:env] if field[:env]
    return (step['fill']['code_source'] || {})['url'].to_s == field[:code_source][:url].to_s if field[:code_source]

    true
  end

  # A bare `wait_for: { state: }` after the submit waits on the login's own
  # navigation; a seeded case never makes it, so it goes with the login.
  def navigation_wait?(step)
    return false unless step.is_a?(Hash) && step['wait_for'].is_a?(Hash)

    wait = step['wait_for']
    wait.key?('state') && !wait.key?('selector') && !wait.key?('url_contains')
  end

  def value(step, verb, key)
    return nil unless step.is_a?(Hash) && step.key?(verb)

    raw = step[verb]
    raw.is_a?(Hash) ? raw[key]&.to_s : raw.to_s
  end

  # A flow names the login page with whatever host it explored; the config
  # names a path. They match on the path and, since a hash route (#/login) is
  # the page in a client-routed app, on that route too. A query the config
  # names (a tenant, an auth mode) picks the login, so the flow must carry
  # every one of its params; extra flow params such as a redirect are fine.
  def same_path?(flow_url, auth_url)
    return false if flow_url.nil?

    flow = URI.parse(flow_url.to_s)
    auth = URI.parse(auth_url.to_s)
    page(flow) == page(auth) && (params(auth).to_a - params(flow).to_a).empty?
  rescue URI::InvalidURIError, ArgumentError
    false
  end

  def page(uri)
    fragment = uri.fragment.to_s
    [ uri.path.to_s.sub(%r{/\z}, ''), fragment.start_with?('/') ? fragment.split('?').first : '' ]
  end

  def params(uri) = URI.decode_www_form(uri.query.to_s)
end

# Runs one declarative flow file against an ephemeral browserless Chromium
# container and prints the per-step result as JSON.
#
#   ruby scripts/change_flow_run.rb flow.yml --base-url http://127.0.0.1:3000
#   ruby scripts/change_flow_run.rb flow.yml --dump      # compile only, no run
#   ruby scripts/change_flow_run.rb flow.yml --base-url https://app.local.example.test \
#     --add-host app.local.example.test:host-gateway --ignore-https-errors
#
# The browser runs in a container, so a dev hostname from the host's
# /etc/hosts needs `--add-host HOST:TARGET` (repeatable; `host-gateway` is the
# host), and a local dev CA the container does not trust needs
# `--ignore-https-errors`. The latter is refused unless the base URL is a local
# host, and the run then aborts HTTPS requests to any non-local host, so it can
# never skip a real certificate. Both can also come from CHANGE.md's
# change_config.boot (add_hosts, ignore_https_errors) via --profile NAME or
# --change-md PATH, so a profile describes its own local dev host once.
#
# The flow file is either a bare list of steps or a mapping carrying
# `base_url`, `timeout_ms`, `viewport` ({ width:, height: }), and `steps`. A
# command-line `--base-url` wins over the file's, so the same flow file runs
# against any environment without being edited.
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

    apply_change_md(options)
    base_url = options[:base_url] || flow['base_url'] || options[:config_base_url]
    check_ignore_https(options, base_url)
    compiler = ChangeFlowCompiler.new(
      flow['steps'],
      base_url: base_url,
      timeout_ms: flow['timeout_ms'] || ChangeFlowCompiler::DEFAULT_TIMEOUT_MS,
      viewport: flow['viewport']
    )
    puts(options[:dump] ? compiler.dump : JSON.pretty_generate(execute(compiler, options)))
    0
  rescue ChangeFlowCompiler::Error, ChangeConfig::ConfigError, ArgumentError => e
    warn "flow error: #{e.message}"
    1
  end

  # Renders the flow as a committed test case, so an exploratory run can end in
  # a suite file instead of a transcript. It only prints: whoever invoked it
  # shows the YAML as a diff and writes it on an explicit answer, never
  # automatically and never as a commit.
  #
  # The suite id defaults to the flow file's name. When the flow opens with a
  # configured persona's login (its login page, fields and submit, in order),
  # the case names that persona and drops those steps, so the committed case
  # logs in the way the lane does instead of typing credentials itself.
  # `--persona NAME` names it outright.
  def promote(flow, options)
    safe_rerun = flow['safe_rerun'] == true
    persona, steps = promoted_persona(flow['steps'], options)
    puts ChangeSuiteRender.suite_yaml(
      steps: steps, suite: options[:suite] || default_suite(options[:path]), id: options[:case_id],
      acceptance: options[:acceptance], tags: options[:tags], retries: flow['retries'], safe_rerun: safe_rerun,
      persona: persona
    )
    warn "promote note: replaced the flow's login steps with persona: #{persona}" if persona && steps != flow['steps']
    if ChangeSuiteRender.dropped_retries?(flow['retries'], safe_rerun)
      warn "promote note: dropped retries: #{flow['retries']}; a case reruns only with safe_rerun: true, " \
           'so add both by hand if replaying every step of a failed attempt is safe'
    end
    0
  rescue ChangeSuiteRender::Error, ChangeConfig::ConfigError => e
    warn "promote error: #{e.message}"
    1
  end

  # `checkout.flow.yml` promotes as suite `checkout`.
  def default_suite(path) = File.basename(path.to_s).sub(/\..*\z/, '')

  # [persona name or nil, the steps to commit]. A forced `--persona` still
  # drops that persona's login prefix when the flow starts with it.
  def promoted_persona(steps, options)
    personas = configured_personas(options)
    if options[:persona]
      auth = personas[options[:persona]]
      return [ options[:persona], steps.drop(auth ? ChangeFlowLogin.prefix_length(steps, auth) : 0) ]
    end

    personas.each do |name, auth|
      length = ChangeFlowLogin.prefix_length(steps, auth)
      return [ name, steps.drop(length) ] if length.positive?
    end
    [ nil, steps ]
  end

  # name => AuthConfig, `default` first (the lane's auth:), from CHANGE.md when
  # one is named or sits in the working directory.
  def configured_personas(options)
    path = options[:change_md] || File.join(Dir.pwd, 'CHANGE.md')
    return {} unless options[:change_md] || options[:profile] || File.exist?(path)

    lane = ChangeConfig.load(path, profile: options[:profile]).lane('testcases')
    blocks = {}
    blocks['default'] = lane['auth'] if lane['auth'].is_a?(Hash)
    blocks.merge!(lane['personas'].transform_keys(&:to_s)) if lane['personas'].is_a?(Hash)
    blocks.select { |_name, raw| raw.is_a?(Hash) }.transform_values { |raw| ChangeLaneBrowserless::AuthConfig.new(raw) }
  end

  def execute(compiler, options)
    raise 'docker is unavailable; cannot run a browser flow' unless ChangeDocker.available?

    ChangeDocker.with_network(options[:network]) do |net|
      ChangeDocker.with_browserless(network: net.name, add_hosts: options[:add_hosts],
                                    local_tls_hosts: options[:allowed_hosts]) do |session|
        session.run_function(compiler.function_module, launch_args: options[:launch_args])
      end
    end
  end

  def check_ignore_https(options, base_url)
    options[:allowed_hosts] = ChangeLocalTls.allowed_hosts(base_url, options[:add_hosts]) if options[:ignore_https_errors]
  end

  # `--profile NAME` (or `--change-md PATH`) reads change_config.boot from the
  # repo's CHANGE.md: add_hosts and ignore_https_errors join the flags, and
  # target_url is the base URL when neither flag nor flow file names one.
  def apply_change_md(options)
    return unless options[:profile] || options[:change_md]

    config = ChangeConfig.load(options[:change_md] || File.join(Dir.pwd, 'CHANGE.md'), profile: options[:profile])
    boot = config.boot
    options[:launch_args] = (Array(config.lane('testcases')['launch_args']) + options[:launch_args]).uniq
    options[:add_hosts] = (boot.add_hosts + options[:add_hosts]).uniq
    options[:ignore_https_errors] ||= boot.ignore_https_errors
    options[:config_base_url] = boot.target_url unless boot.target_url.empty?
  end

  def load_flow(path)
    raw = YAML.safe_load_file(path, permitted_classes: [], aliases: true)
    return { 'steps' => raw } if raw.is_a?(Array)
    raise ChangeFlowCompiler::Error, "#{path} carries no steps:" unless raw.is_a?(Hash) && raw['steps']

    raw
  end

  def parse(argv)
    options = { path: nil, base_url: nil, network: nil, dump: false, promote: false,
                suite: nil, case_id: nil, acceptance: nil, tags: [], add_hosts: [], ignore_https_errors: false,
                launch_args: [] }
    until argv.empty?
      arg = argv.shift
      case arg
      when '--base-url' then options[:base_url] = argv.shift
      when '--network' then options[:network] = argv.shift
      when '--add-host' then options[:add_hosts] << add_host(argv.shift)
      when '--ignore-https-errors' then options[:ignore_https_errors] = true
      when '--launch-arg' then options[:launch_args] << launch_arg(argv.shift)
      when '--profile' then options[:profile] = argv.shift
      when '--change-md' then options[:change_md] = argv.shift
      when '--dump' then options[:dump] = true
      when '--promote' then options[:promote] = true
      when '--suite' then options[:suite] = argv.shift
      when '--persona' then options[:persona] = argv.shift
      when '--case-id' then options[:case_id] = argv.shift
      when '--acceptance' then options[:acceptance] = argv.shift
      when '--tags' then options[:tags] = argv.shift.to_s.split(',')
      else options[:path] ||= arg
      end
    end
    options
  end

  # A Chromium flag for the browserless launch, e.g.
  # --launch-arg=--disable-features=LocalNetworkAccessChecks.
  def launch_arg(value)
    raise ArgumentError, "--launch-arg needs a Chromium flag starting with '--', got #{value.inspect}" unless value.to_s.match?(/\A--\S/)

    value
  end

  # HOST:TARGET, where TARGET is an IP or docker's `host-gateway`.
  def add_host(value)
    host, target = value.to_s.split(':', 2)
    raise ArgumentError, "--add-host wants HOST:TARGET, got #{value.inspect}" if host.to_s.empty? || target.to_s.empty?

    "#{host}:#{target}"
  end

  def usage
    warn 'usage: change_flow_run.rb <flow.yml> [--base-url URL] [--network NAME] [--dump]'
    warn '       [--add-host HOST:TARGET ...] [--ignore-https-errors] [--launch-arg FLAG ...] [--profile NAME] [--change-md PATH]'
    warn '       change_flow_run.rb <flow.yml> --promote [--suite NAME] --case-id ID ' \
         '--acceptance TEXT [--tags a,b] [--persona NAME]'
    2
  end
end

exit(ChangeFlowRun.main(ARGV)) if __FILE__ == $PROGRAM_NAME
