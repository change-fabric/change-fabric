#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'
require 'ipaddr'
require 'uri'
require_relative 'change_docker'
require_relative 'change_flow_compiler'
require_relative 'change_suite_render'

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
# never skip a real certificate.
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

    base_url = options[:base_url] || flow['base_url']
    check_ignore_https(options, base_url)
    compiler = ChangeFlowCompiler.new(
      flow['steps'],
      base_url: base_url,
      timeout_ms: flow['timeout_ms'] || ChangeFlowCompiler::DEFAULT_TIMEOUT_MS
    )
    puts(options[:dump] ? compiler.dump : JSON.pretty_generate(execute(compiler, options)))
    0
  rescue ChangeFlowCompiler::Error, ArgumentError => e
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

  def execute(compiler, options)
    raise 'docker is unavailable; cannot run a browser flow' unless ChangeDocker.available?

    code = compiler.function_module
    launch_args = []
    if options[:ignore_https_errors]
      code = local_https_only(code, options[:allowed_hosts])
      launch_args = [ '--ignore-certificate-errors' ]
    end
    ChangeDocker.with_network(options[:network]) do |net|
      ChangeDocker.with_browserless(network: net.name, add_hosts: options[:add_hosts]) do |session|
        session.run_function(code, launch_args: launch_args)
      end
    end
  end

  ENTRY = 'export default async ({ page }) => {'

  # The Chromium flag is browser-wide, so a flow that navigated, redirected, or
  # loaded a resource from a public HTTPS host would skip that certificate too.
  # Abort every HTTPS request to a host outside the local allowlist instead.
  # Chrome upgrades plain http to https first, so a public http URL is blocked
  # too while the flag is on; the flag is only for local apps.
  def local_https_only(code, hosts)
    raise ArgumentError, 'flow module entry point changed; cannot scope --ignore-https-errors' unless code.include?(ENTRY)

    code.sub(ENTRY, <<~JS.chomp)
      #{ENTRY}
        const cfLocalHosts = #{JSON.generate(hosts)};
        await page.setRequestInterception(true);
        page.on("request", (request) => {
          const url = new URL(request.url());
          if (url.protocol === "https:" && !cfLocalHosts.includes(url.hostname)) return request.abort("accessdenied");
          return request.continue();
        });
    JS
  end

  LOCAL_SUFFIXES = %w[.localhost .local .test .internal].freeze

  def check_ignore_https(options, base_url)
    return unless options[:ignore_https_errors]

    unless local_host?(base_url, options[:add_hosts])
      raise ArgumentError, '--ignore-https-errors needs a local base URL (localhost, *.localhost, *.local, *.test, ' \
                           '*.internal, a private IP, or a name --add-host maps to host-gateway or a private IP); ' \
                           "got #{base_url.inspect}"
    end
    options[:allowed_hosts] = ([ host_of(base_url) ] + options[:add_hosts].map { |entry| entry.split(':', 2).first.downcase })
                              .select { |host| local_name?(host, options[:add_hosts]) }.uniq
  end

  # Local means a name or address that cannot carry a publicly issued
  # certificate, or one this run explicitly pins to the host or a private
  # address, so ignoring its certificate skips nothing a real user relies on.
  def local_host?(url, add_hosts = [])
    local_name?(host_of(url), add_hosts)
  rescue URI::InvalidURIError
    false
  end

  def local_name?(host, add_hosts)
    return false if host.empty?
    return true if host == 'localhost' || LOCAL_SUFFIXES.any? { |suffix| host.end_with?(suffix) }
    return true if private_ip?(host)

    add_hosts.any? do |entry|
      name, target = entry.split(':', 2)
      name.downcase == host && (target == 'host-gateway' || private_ip?(target))
    end
  end

  def private_ip?(value)
    ip = IPAddr.new(value.to_s)
    ip.loopback? || ip.private? || ip.link_local?
  rescue IPAddr::InvalidAddressError
    false
  end

  def host_of(url) = URI(url.to_s).host.to_s.downcase.delete_prefix('[').delete_suffix(']')

  def load_flow(path)
    raw = YAML.safe_load_file(path, permitted_classes: [], aliases: true)
    return { 'steps' => raw } if raw.is_a?(Array)
    raise ChangeFlowCompiler::Error, "#{path} carries no steps:" unless raw.is_a?(Hash) && raw['steps']

    raw
  end

  def parse(argv)
    options = { path: nil, base_url: nil, network: nil, dump: false, promote: false,
                suite: nil, case_id: nil, acceptance: nil, tags: [], add_hosts: [], ignore_https_errors: false }
    until argv.empty?
      arg = argv.shift
      case arg
      when '--base-url' then options[:base_url] = argv.shift
      when '--network' then options[:network] = argv.shift
      when '--add-host' then options[:add_hosts] << add_host(argv.shift)
      when '--ignore-https-errors' then options[:ignore_https_errors] = true
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

  # HOST:TARGET, where TARGET is an IP or docker's `host-gateway`.
  def add_host(value)
    host, target = value.to_s.split(':', 2)
    raise ArgumentError, "--add-host wants HOST:TARGET, got #{value.inspect}" if host.to_s.empty? || target.to_s.empty?

    "#{host}:#{target}"
  end

  def usage
    warn 'usage: change_flow_run.rb <flow.yml> [--base-url URL] [--network NAME] [--dump]'
    warn '       [--add-host HOST:TARGET ...] [--ignore-https-errors]'
    warn '       change_flow_run.rb <flow.yml> --promote --suite NAME --case-id ID ' \
         '--acceptance TEXT [--tags a,b]'
    2
  end
end

exit(ChangeFlowRun.main(ARGV)) if __FILE__ == $PROGRAM_NAME
