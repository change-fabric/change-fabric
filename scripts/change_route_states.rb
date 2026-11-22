# frozen_string_literal: true

require_relative 'change_findings'
require_relative 'change_flow_selector'
require_relative 'change_selector_suggestions'

# Layout stability for the states of a route (`routes[].states[]` on the
# browserless lane, schema 0.32.0). A route is loaded, then each declared state
# is reached from a fresh load by clicking `click` and waiting for `ready`, and
# the lane reads facts: the rect of each `watch` selector before and after, and
# the page width once the state settled. This module owns the config shape, the
# browser-side reader and the host-side grading, so the lane only wires it in.
#
# Grading is host-side on plain numbers so it can be tested without a browser:
# a watched element that moved or resized past `tolerance_px`, one that is
# missing before or after, a state that could not be reached, or a page wider
# than the viewport in that state, is a fail. A state is never skipped quietly:
# a malformed one is reported as a config finding and the rest still run.
#
# Everything that came from config or the page goes through
# `ChangeSelectorSuggestions.safe` before it reaches a finding.
module ChangeRouteStates
  NAME = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,47}\z/
  KEYS = %w[name click ready watch tolerance_px timeout_ms].freeze
  MAX_STATES = 8
  MAX_WATCH = 8
  DEFAULT_TIMEOUT_MS = 5_000
  MAX_TIMEOUT_MS = 15_000
  MAX_TOLERANCE_PX = 10_000
  STATE_BUDGET_MS = 40_000
  RELOAD_LIMIT_MS = 20_000
  SELECTOR_MAX = 200
  RECT_KEYS = %w[x y width height].freeze

  State = Struct.new(:name, :click, :ready, :watch, :tolerance_px, :timeout_ms, keyword_init: true) do
    def to_js = { name: name, click: click, ready: ready, watch: watch, timeoutMs: timeout_ms }
  end

  module_function

  def safe(value) = ChangeSelectorSuggestions.safe(value)

  # `raw` is a route's `states:` value. Returns [states, errors]: every valid
  # state in order, and one message per problem. Absent and empty are both
  # fine and mean no states; a value that is not a list is one error.
  def normalize(raw)
    return [ [], [] ] if raw.nil?
    return [ [], [ 'states must be a list' ] ] unless raw.is_a?(Array)

    errors = []
    errors << "more than #{MAX_STATES} states; the rest are ignored" if raw.length > MAX_STATES
    seen = {}
    states = raw.first(MAX_STATES).each_with_index.filter_map do |item, index|
      state, problem = build(item, seen)
      errors << "states[#{index}]: #{problem}" if problem
      state
    end
    [ states, errors ]
  end

  def build(item, seen)
    return [ nil, 'must be a mapping' ] unless item.is_a?(Hash)

    unknown = item.keys.map(&:to_s) - KEYS
    return [ nil, "unknown key #{safe(unknown.first)}" ] unless unknown.empty?

    name = item['name'].to_s
    return [ nil, "name #{safe(name)} must match #{NAME.source}" ] unless NAME.match?(name)
    return [ nil, "duplicate name #{name}" ] if seen[name]

    fields = state_fields(item)
    return [ nil, "#{name}: #{fields}" ] if fields.is_a?(String)

    seen[name] = true
    [ State.new(name: name, **fields), nil ]
  end

  def state_fields(item)
    click = item['click']
    ready = item['ready']
    return 'needs click or ready' if click.nil? && ready.nil?

    watch = item['watch'].nil? ? [] : item['watch']
    return 'watch must be a list of selectors' unless watch.is_a?(Array)
    return "watch is capped at #{MAX_WATCH} selectors" if watch.length > MAX_WATCH

    problem = (([ click, ready ].compact) + watch).filter_map { |selector| selector_problem(selector) }.first
    return problem if problem

    tolerance = item.fetch('tolerance_px', 0)
    unless tolerance.is_a?(Numeric) && (0..MAX_TOLERANCE_PX).cover?(tolerance)
      return "tolerance_px must be a number from 0 to #{MAX_TOLERANCE_PX}"
    end

    timeout = item.fetch('timeout_ms', DEFAULT_TIMEOUT_MS)
    unless timeout.is_a?(Integer) && timeout.positive? && timeout <= MAX_TIMEOUT_MS
      return "timeout_ms must be 1 to #{MAX_TIMEOUT_MS}"
    end

    { click: click, ready: ready, watch: watch.uniq, tolerance_px: tolerance, timeout_ms: timeout }
  end

  # Selectors are resolved in the page with the DOM's own query, so a text or
  # nth locator has no meaning here. Refused rather than passed unmeasured.
  def selector_problem(selector)
    return "selector #{safe(selector)} must be a non-empty string" unless selector.is_a?(String) && !selector.strip.empty?
    return "selector #{safe(selector)} is over #{SELECTOR_MAX} characters" if selector.length > SELECTOR_MAX

    plain = !ChangeFlowSelector.locator(selector) && !selector.include?('::-p-')
    plain ? nil : "selector #{safe(selector)} must be plain CSS"
  rescue StandardError
    "selector #{safe(selector)} is not valid CSS"
  end

  # The in-page runner, spliced into the scan module. `reload` brings the
  # route back to a clean load before every state, the first included: the
  # checks that ran earlier in the cell (a Figma diff injects style overrides)
  # must not change what a state measures. Persisted storage and cookies are
  # not cleared, so a state that stores something can affect a later one.
  # Every await has a deadline and the whole run has a budget, because one
  # hung click would otherwise cost every cell of the viewport its result.
  # Failures are caught per state.
  def runtime_js
    <<~JS
      const STATE_BUDGET_MS = #{STATE_BUDGET_MS};
      const STATE_RELOAD_MS = #{RELOAD_LIMIT_MS};

      function withDeadline(promise, ms, what) {
        let timer;
        const deadline = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(what + " took over " + ms + "ms")), ms); });
        return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
      }

      // A zero-size box (display none) reads as absent: it has no layout to hold still.
      async function readRects(statePage, selectors) {
        return statePage.evaluate((list) => list.map((selector) => {
          const el = document.querySelector(selector);
          if (!el) return null;
          const r = el.getBoundingClientRect();
          if (r.width === 0 && r.height === 0) return null;
          return { x: r.x + window.scrollX, y: r.y + window.scrollY, width: r.width, height: r.height };
        }), selectors);
      }

      // Fonts ready, two frames painted, then the rects polled until two reads
      // in a row agree, so a transition is not sampled mid-flight.
      async function settledRects(statePage, selectors, limitMs) {
        await withDeadline(statePage.evaluate(async () => {
          if (document.fonts && document.fonts.ready) await document.fonts.ready;
          await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
        }), limitMs, "fonts and paint");
        const until = Date.now() + limitMs;
        let last = JSON.stringify(await readRects(statePage, selectors));
        while (Date.now() < until) {
          await new Promise((done) => setTimeout(done, 50));
          const next = JSON.stringify(await readRects(statePage, selectors));
          if (next === last) return JSON.parse(last);
          last = next;
        }
        throw new Error("layout did not settle in " + limitMs + "ms");
      }

      async function runOneState(statePage, st, reload) {
        const result = { name: st.name };
        try {
          await withDeadline(reload(), STATE_RELOAD_MS, "reload");
          if (st.click) await statePage.waitForSelector(st.click, { visible: true, timeout: st.timeoutMs });
          const before = await settledRects(statePage, st.watch, st.timeoutMs);
          if (st.click) await withDeadline(statePage.click(st.click), st.timeoutMs, "click");
          if (st.ready) await statePage.waitForSelector(st.ready, { visible: true, timeout: st.timeoutMs });
          result.after = await settledRects(statePage, st.watch, st.timeoutMs);
          result.before = before;
          result.scrollWidth = await withDeadline(statePage.evaluate(() => document.documentElement.scrollWidth), st.timeoutMs, "width read");
        } catch (err) {
          result.error = String(err);
        }
        return result;
      }

      async function runStates(statePage, states, reload) {
        const started = Date.now();
        const onDialog = (dialog) => { dialog.dismiss().catch(() => {}); };
        statePage.on("dialog", onDialog);
        const results = [];
        try {
          for (const st of states) {
            if (Date.now() - started > STATE_BUDGET_MS) {
              results.push({ name: st.name, error: "state budget of " + STATE_BUDGET_MS + "ms was used up" });
              continue;
            }
            results.push(await runOneState(statePage, st, reload));
          }
        } finally {
          try { statePage.off("dialog", onDialog); } catch (err) { void err; }
        }
        return results;
      }
    JS
  end

  # --- host-side grading ------------------------------------------------------

  # Findings for one cell. `declared` is the route's normalized states, so a
  # state the browser never reported is still named, never dropped.
  def findings(cell, declared, target:)
    reported = Array(cell['states']).select { |entry| entry.is_a?(Hash) }.to_h { |entry| [ entry['name'].to_s, entry ] }
    declared.map do |state|
      status, severity, detail = grade(state, reported[state.name], cell)
      Finding.new(lane: 'browserless', check: "#{cell['viewport']} state #{state.name}", target: target,
                  status: status, severity: severity, location: safe(cell['route']), detail: safe(detail))
    end
  end

  def grade(state, result, cell)
    return [ 'fail', 'medium', 'state was not run: login failed for this route' ] if cell['authBlocked']
    return [ 'fail', 'medium', 'state was not run: the route did not load' ] if cell['error']
    return [ 'fail', 'medium', 'state was not reported by the browser' ] unless result
    return [ 'fail', 'high', "state could not be reached: #{result['error']}" ] if result['error']

    problem = overflow(result, cell) || moved(state, result)
    problem ? [ 'fail', 'medium', problem ] : [ 'pass', 'info', 'layout stable' ]
  end

  def overflow(result, cell)
    width = result['scrollWidth']
    return nil unless width.is_a?(Numeric) && cell['width'].is_a?(Numeric)

    "horizontal overflow in this state: scrollWidth #{width} > #{cell['width']}" if width > cell['width'] + 1
  end

  def moved(state, result)
    before = Array(result['before'])
    after = Array(result['after'])
    state.watch.each_with_index do |selector, index|
      from = before[index]
      to = after[index]
      unless from.is_a?(Hash) && to.is_a?(Hash)
        return "#{safe(selector)} is missing or hidden #{from.is_a?(Hash) ? 'after' : 'before'} the state " \
               '(only the main document is searched)'
      end

      delta = shift(from, to)
      return "#{safe(selector)} moved or resized by #{delta.round(1)}px (tolerance #{state.tolerance_px}px)" if delta > state.tolerance_px
    end
    nil
  end

  # The largest change in any edge, so a pure resize counts like a move.
  def shift(from, to)
    edges(from).zip(edges(to)).map { |before, after| (after - before).abs }.max
  end

  # left, top, right, bottom: a move plus a resize can shift one edge by more
  # than either the position or the size changed on its own.
  def edges(rect)
    x, y, width, height = RECT_KEYS.map { |key| rect[key].to_f }
    [ x, y, x + width, y + height ]
  end

  def config_findings(entry, target:)
    Array(entry[:state_errors]).map do |message|
      Finding.new(lane: 'browserless', check: 'route states config', target: target, status: 'fail',
                  severity: 'medium', location: safe(entry[:path]), detail: safe("#{entry[:path]} #{message}"))
    end
  end
end
