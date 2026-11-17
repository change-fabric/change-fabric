# frozen_string_literal: true

require 'json'
require_relative 'walkthrough_live'
require_relative 'walkthrough_storyboard'
require_relative 'walkthrough_element'
require_relative 'change_docker'

# The free capture-side preflight a render runs before any paid call
# (narration, music, image, b-roll, roast). It checks what would otherwise
# fail only after money was spent:
#
# 1. local assets: the installed JS runtimes capture injects, and every
#    screen html or store seed a targeted scene names;
# 2. live config: each live scene's persona is defined with a login, and
#    every env var the board types or logs in with is set;
# 3. selectors: for each live scene reachable without a session, its wait
#    selector and every interaction target up to the first state-changing
#    op exist on its page once loaded, and each persona's login page holds
#    its login step selectors. Best effort, in the live browserless
#    container; an unreachable app fails the preflight.
#
# Scenes that start from a session (persona or session_from_scene) are not
# selector-checked on their own page, since reaching it needs a login that
# is the capture's job; the login page itself is checked.
module WalkthroughPreflight
  class Error < StandardError; end

  RUNTIMES = [ File.join(__dir__, 'walkthrough_ease.js'), WalkthroughElement::RUNTIME ].freeze
  # Ops after which the page may show elements it did not have on load.
  STATE_OPS = %w[click dblclick tap key].freeze
  SELECTOR_TIMEOUT_MS = 3000
  GOTO_TIMEOUT_MS = 20_000

  module_function

  def asset_errors(root, scenes, runtimes: RUNTIMES)
    missing = runtimes.reject { |path| File.file?(path) }
                      .map { |path| "runtime #{path} is not installed; re-run install.rb" }
    missing + scenes.flat_map do |scene|
      [ scene.dig('screen', 'html'), scene.dig('store', 'seed') ].compact
        .reject { |rel| File.file?(File.join(root, rel)) }
        .map { |rel| "#{scene['id']}: #{rel} is missing" }
    end
  end

  # A persona's login block, or nil when the persona or its login is absent.
  def login_for(board, name)
    persona = (board['personas'] || {})[name]
    login = persona.is_a?(Hash) ? persona['login'] : nil
    login.is_a?(Hash) ? login : nil
  end

  def persona_scenes(scenes) = scenes.select { |s| WalkthroughLive.live?(s) && s['persona'] }

  def live_config_errors(board, scenes, env: ENV)
    errs = persona_scenes(scenes).reject { |s| login_for(board, s['persona']) }
                                 .map { |s| "#{s['id']}: persona #{s['persona'].inspect} has no login config" }
    return errs unless scenes.any? { |s| WalkthroughLive.realtime?(s) }

    unset = WalkthroughLive.env_names(board).select { |n| env[n].to_s.empty? }
    errs + unset.map { |n| "env #{n} is not set (a live scene needs it)" }
  end

  # One job per page to load: { 'label', 'url', 'selectors' }.
  def selector_jobs(board, scenes)
    logins = persona_scenes(scenes).map { |s| s['persona'] }.uniq.filter_map do |name|
      login = login_for(board, name)
      next unless login

      { 'label' => "persona #{name} login", 'url' => login['url'],
        'selectors' => Array(login['steps']).filter_map { |st| st['selector'] }.uniq }
    end
    pages = scenes.select { |s| WalkthroughLive.live?(s) && !s['persona'] && !s['session_from_scene'] }.map do |scene|
      { 'label' => scene['id'], 'url' => WalkthroughLive.url(scene), 'selectors' => scene_selectors(scene) }
    end
    (logins + pages).reject { |j| j['url'].to_s.empty? }
  end

  def scene_selectors(scene)
    list = [ scene.dig('screen', 'wait', 'selector') ].compact
    ops = WalkthroughLive.all_interactions(scene)
    ops.each do |op|
      target = op['target']
      list << target if target.is_a?(String) && !target.empty?
      break if STATE_OPS.include?(op['op'])
    end
    list.uniq
  end

  def check_js(board, jobs)
    <<~JS
      export default async function ({ page: basePage }) {
        #{WalkthroughLive.page_setup_js(WalkthroughLive.browser_opts(board)['ignore_https_errors'])}
        const results = [];
        for (const job of #{JSON.generate(jobs)}) {
          const { context, page } = await openPage({ w: 1280, h: 800, dpr: 1 });
          const res = { label: job.label, url: job.url, missing: [], error: null };
          try {
            await page.goto(job.url, { waitUntil: "domcontentloaded", timeout: #{GOTO_TIMEOUT_MS} });
            for (const sel of job.selectors) {
              try { await page.waitForSelector(sel, { timeout: #{SELECTOR_TIMEOUT_MS} }); }
              catch { res.missing.push(sel); }
            }
          } catch (e) {
            res.error = String(e && e.message || e);
          }
          results.push(res);
          try { context ? await context.close() : await page.close(); } catch { }
        }
        return { data: { results }, type: "application/json" };
      }
    JS
  end

  def selector_errors(results)
    Array(results).flat_map do |r|
      if r['error']
        reason = first_line(r['error'])
        next [ "#{r['label']}: cannot reach #{r['url']} (#{reason}); start the app or fix the URL" ]
      end

      Array(r['missing']).map { |sel| "#{r['label']}: selector #{sel.inspect} not found on #{r['url']}" }
    end
  end

  # Opens the board's live browserless container and checks every job; a
  # container that will not start is a preflight failure, not a crash.
  def check_live(board, jobs)
    return [] if jobs.empty?

    opts = WalkthroughLive.browser_opts(board)
    ChangeDocker.with_browserless(network: opts['network'], add_hosts: opts['add_hosts'] || []) do |session|
      check_selectors(session, board, jobs)
    end
  rescue StandardError => e
    [ "live browser could not start (#{first_line(e.message)}); check the board's browser network" ]
  end

  # A crash inside the check is a preflight failure, not a render crash.
  def check_selectors(session, board, jobs)
    return [] if jobs.empty?

    data = session.run_function(check_js(board, jobs))
    data = JSON.parse(data) if data.is_a?(String)
    selector_errors(data['results'])
  rescue StandardError => e
    [ "selector check could not run (#{e.class}: #{first_line(e.message)}); is the app reachable?" ]
  end

  def first_line(text) = text.to_s.lines.first.to_s.strip
end
