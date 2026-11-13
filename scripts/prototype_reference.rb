#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'change_apps'
require_relative 'change_docker'
require_relative 'change_env'
require_relative 'change_flow_compiler'
require_relative 'change_lane_browserless'
require_relative 'design_config'

# Captures a design target's reference routes (spec 0.18.0) from the running
# app in browserless, for the fidelity critic to compare with prototype
# stills. Auth reuses the lane login-flow shape: reference.auth is either a
# lane name, resolved to the linked app's own lane auth block, or a block of
# that shape. Credentials come from env var names only, a missing one is a
# named failure (never an unauthenticated fallback), every value is masked in
# any message, and the login session lives only inside the one browserless
# call. Stills land in the ignored .cache/reference/<target>/ and are never
# committed or published.
module PrototypeReference
  class Error < StandardError; end

  CACHE = File.join('.cache', 'reference')
  DEFAULT_VIEWPORT = { 'w' => 1440, 'h' => 900, 'dpr' => 1 }.freeze
  NAV_TIMEOUT_MS = 30_000

  Plan = Data.define(:target, :base_url, :routes, :auth)

  module_function

  # The linked app's ChangeConfig, by name from the root registry.
  def default_app_loader
    lambda do |root, name|
      registry = ChangeAppRegistry.load(File.join(root, 'CHANGE.md'))
      entry = registry.entries.find { |e| e.name == name } || raise(Error, "change_config.apps has no app '#{name}'")
      entry.load
    end
  end

  def plan(root, name, app_loader: default_app_loader)
    config = DesignConfig.load(root).target(name)
    target = config.target
    raise Error, "design target '#{target.name}' names no reference" unless target.reference?

    ref = target.reference
    app = target.app && app_loader.call(root, target.app)
    base = ref.base_url || (app && app.lane('browserless').base_url(app.boot.target_url))
    raise Error, "design target '#{target.name}' has no reference base_url and no linked app to take one from" if base.to_s.empty?

    Plan.new(target: target.name, base_url: base.to_s.chomp('/'), routes: ref.routes, auth: auth_block(target, ref.auth, app))
  end

  # A lane name resolves to that lane's auth block in the linked app's config.
  def auth_block(target, auth, app)
    return nil if auth.nil?
    return auth if auth.is_a?(Hash)

    raise Error, "design target '#{target.name}' names auth lane '#{auth}' but links no app" unless app

    block = app.lane(auth)['auth']
    raise Error, "app '#{target.app}' lanes.#{auth} has no auth block for reference.auth to reuse" unless block.is_a?(Hash)

    block
  end

  # Every env var name an auth block reads.
  def env_names(auth)
    return [] unless auth

    top = auth.select { |k, _| k.to_s.end_with?('_env') }.values
    fields = Array(auth['steps']).flat_map { |s| Array(s['fields']).filter_map { |f| f['env'] } }
    (top + fields).map(&:to_s).uniq
  end

  # Resolves the credentials by name. A literal secret never reaches here: the
  # schema rejects one at load. Raises Error naming every unset variable.
  def credentials(auth, source: ENV)
    ChangeEnv.build(declared: env_names(auth), source: source)
  rescue ChangeEnv::MissingVariables => e
    raise Error, "reference login needs env var(s) that are not set: #{e.names.join(', ')}; " \
                 'no unauthenticated capture is attempted'
  end

  # The lane's own normalization (one step for the single-form shape), with
  # each field's value read from `source` by its env name.
  def compiled_auth(auth, base_url, source: ENV)
    return nil unless auth

    steps = ChangeLaneBrowserless::AuthConfig.new(auth).steps.map do |step|
      step.merge(fields: step[:fields].map { |f| f[:env] ? f.merge(value: source[f[:env]].to_s) : f })
    end
    ChangeFlowCompiler.compile_auth(steps, base_url: base_url)
  end

  def cache_dir(root, target) = File.join(root, CACHE, target)

  # A .gitignore of `*` at the cache root keeps every reference still out of
  # git, whatever the repo's own ignore rules say.
  def ensure_ignored(root)
    dir = File.join(root, CACHE)
    FileUtils.mkdir_p(dir)
    file = File.join(dir, '.gitignore')
    File.write(file, "*\n") unless File.file?(file) && File.read(file).lines.map(&:strip).include?('*')
    file
  end

  def still_name(path) = "#{path.delete_prefix('/').gsub(/[^A-Za-z0-9]+/, '-').sub(/-\z/, '').then { |s| s.empty? ? 'root' : s }}.png"

  # The browserless /function module: log in once, then for each route load
  # it, hide mask selectors (layout kept, so the critic sees structure), and
  # screenshot the viewport.
  def capture_module(plan, auth_js, viewport)
    routes = plan.routes.map { |r| { path: r.path, mask: r.mask } }
    <<~JS
      export default async function ({ page }) {
        const baseUrl = #{JSON.generate(plan.base_url)};
        const routes = #{JSON.generate(routes)};
        const auth = #{JSON.generate(auth_js)};
        #{ChangeFlowCompiler.auth_runtime_js}
        await page.setViewport({ width: #{viewport['w'].to_i}, height: #{viewport['h'].to_i}, deviceScaleFactor: #{viewport['dpr'] || 1} });
        if (auth) {
          const session = { page: page, lastAuthResponse: null };
          try {
            for (const step of auth.steps) await runAuthStep(session, step);
          } catch (err) {
            return { data: { authError: String(err) }, type: "application/json" };
          }
        }
        const out = [];
        for (const route of routes) {
          try {
            const resp = await page.goto(baseUrl + route.path, { waitUntil: "networkidle2", timeout: #{NAV_TIMEOUT_MS} });
            const status = resp ? resp.status() : null;
            await page.evaluate((selectors) => {
              for (const sel of selectors) for (const el of document.querySelectorAll(sel)) el.style.setProperty("visibility", "hidden", "important");
            }, route.mask);
            const png = await page.screenshot({ type: "png", encoding: "base64" });
            out.push({ path: route.path, status, png });
          } catch (err) {
            out.push({ path: route.path, error: String(err) });
          }
        }
        return { data: out, type: "application/json" };
      }
    JS
  end

  # Captures every reference route. Returns the written still paths; raises
  # Error (masked) on a failed login or any failed route.
  def capture(root, name, session:, viewport: DEFAULT_VIEWPORT, source: ENV, app_loader: default_app_loader)
    plan = plan(root, name, app_loader: app_loader)
    resolved = credentials(plan.auth, source: source)
    mask = resolved.masker
    result = session.run_function(capture_module(plan, compiled_auth(plan.auth, plan.base_url, source: source), viewport))
    raise Error, mask.call("reference login failed for #{plan.target}: #{result['authError']}") if result.is_a?(Hash) && result['authError']

    ensure_ignored(root)
    dir = cache_dir(root, plan.target)
    FileUtils.mkdir_p(dir)
    Array(result).map do |shot|
      raise Error, mask.call("reference #{shot['path']} failed: #{shot['error']}") if shot['error']
      raise Error, "reference #{shot['path']} answered HTTP #{shot['status']}" unless shot['status'].to_i.between?(200, 399)

      path = File.join(dir, still_name(shot['path']))
      File.binwrite(path, Base64.decode64(shot['png']))
      path
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = { root: Dir.pwd, viewport: PrototypeReference::DEFAULT_VIEWPORT.dup }
  OptionParser.new do |o|
    o.banner = 'usage: prototype_reference.rb --target <name> [--root DIR] [--width N --height N --dpr N]'
    o.on('--target NAME') { |v| opts[:target] = v }
    o.on('--root DIR') { |v| opts[:root] = File.expand_path(v) }
    o.on('--width N', Integer) { |v| opts[:viewport]['w'] = v }
    o.on('--height N', Integer) { |v| opts[:viewport]['h'] = v }
    o.on('--dpr N', Float) { |v| opts[:viewport]['dpr'] = v }
  end.parse!
  abort('prototype_reference: --target is required') unless opts[:target]
  begin
    paths = ChangeDocker.with_browserless(network: nil) do |session|
      PrototypeReference.capture(opts[:root], opts[:target], session: session, viewport: opts[:viewport])
    end
    paths.each { |p| puts "reference #{p}" }
  rescue PrototypeReference::Error, DesignConfig::Error, ChangeConfig::ConfigError => e
    abort("prototype_reference: #{e.message}")
  end
end
