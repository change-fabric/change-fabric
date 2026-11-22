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
  STATE_LIMIT_MS = 30_000
  # Equal to ChangeDocker::Browserless::FUNCTION_TIMEOUT_MS (a test pins it).
  FUNCTION_TIMEOUT_MS = 115_000
  RESERVE_MS = 15_000
  CELL_RESERVE_MS = 4_000
  MIN_STEP_MS = 250
  INNER_MARGIN_MS = 200
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
  # Every await is capped by the time left before one absolute route deadline
  # (the budget, or the function timeout less a reserve, whichever is sooner),
  # because one hung click would otherwise cost every cell of the viewport its
  # result. `reload(ms)` receives its cap and must honour it.
  # Failures are caught per state.
  def runtime_js
    <<~JS
      const STATE_BUDGET_MS = #{STATE_BUDGET_MS};
      const STATE_RELOAD_MS = #{RELOAD_LIMIT_MS};
      const STATE_LIMIT_MS = #{STATE_LIMIT_MS};
      const FUNCTION_LIMIT_MS = #{FUNCTION_TIMEOUT_MS};
      const STATE_RESERVE_MS = #{RESERVE_MS};
      const CELL_RESERVE_MS = #{CELL_RESERVE_MS};
      const MIN_STEP_MS = #{MIN_STEP_MS};
      const INNER_MARGIN_MS = #{INNER_MARGIN_MS};

      // One absolute deadline per route: the route budget, but never later than
      // the browserless function timeout less a reserve for this cell's cleanup
      // and for every cell still to run after it.
      // `cellCostMs` is what a cell costs without its states (the slowest seen
      // so far, or this cell's own time before its states), floored at
      // CELL_RESERVE_MS, so slow-loading routes reserve what they really need.
      function routeDeadline(scanStarted, cellsLeft, cellCostMs) {
        const reserve = STATE_RESERVE_MS + cellsLeft * Math.max(CELL_RESERVE_MS, cellCostMs);
        return Math.min(Date.now() + STATE_BUDGET_MS, scanStarted + FUNCTION_LIMIT_MS - reserve);
      }

      // The time an await may take: its own limit, or what is left before the
      // deadline if that is less. Nothing left fails the state instead of
      // starting a wait that could outlive the route. Too little left to do the
      // step is the same failure, not a misleading "took over 1ms".
      function capMs(limitMs, deadline, what) {
        const left = deadline - Date.now();
        if (left < MIN_STEP_MS) throw new Error("state budget used up before " + what);
        return Math.min(limitMs, left);
      }

      // The limit handed to a call that has its own timeout (waitForSelector,
      // goto), a little under the outer cap so the call's own timeout error wins
      // and only a call that ignores its timeout is reported as hung.
      function innerMs(limitMs, deadline) {
        return Math.max(1, Math.min(limitMs, deadline - Date.now()) - INNER_MARGIN_MS);
      }

      // Runs `start()` only once the cap is known, so a spent budget never
      // dispatches work (a click, a read) whose late failure nobody handles.
      // A timeout marks the error `hung`: the work behind it may still be running.
      function bounded(start, limitMs, deadline, what) {
        const ms = capMs(limitMs, deadline, what);
        let timer;
        const expiry = new Promise((_, reject) => {
          timer = setTimeout(() => { const err = new Error(what + " took over " + ms + "ms"); err.hung = true; reject(err); }, ms);
        });
        return Promise.race([Promise.resolve().then(start), expiry]).finally(() => clearTimeout(timer));
      }

      // A zero-size box (display none) reads as absent: it has no layout to hold still.
      // The page width is read with the rects, so a state with nothing to watch
      // still waits for its layout to stop moving before the width is graded.
      async function readRects(statePage, selectors) {
        return statePage.evaluate((list) => ({
          pageWidth: document.documentElement.scrollWidth,
          rects: list.map((selector) => {
            const el = document.querySelector(selector);
            if (!el) return null;
            const r = el.getBoundingClientRect();
            if (r.width === 0 && r.height === 0) return null;
            return { x: r.x + window.scrollX, y: r.y + window.scrollY, width: r.width, height: r.height };
          })
        }), selectors);
      }

      async function readRectsBy(statePage, selectors, deadline) {
        return JSON.stringify(await bounded(() => readRects(statePage, selectors), STATE_LIMIT_MS, deadline, "rect read"));
      }

      // Fonts ready, two frames painted, then the rects polled until two reads
      // in a row agree, so a transition is not sampled mid-flight. At least one
      // pair of reads is compared even when the limit is short.
      async function settledRects(statePage, selectors, limitMs, deadline) {
        await bounded(() => statePage.evaluate(async () => {
          if (document.fonts && document.fonts.ready) await document.fonts.ready;
          await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
        }), limitMs, deadline, "fonts and paint");
        const until = Math.min(Date.now() + limitMs, deadline);
        let last = await readRectsBy(statePage, selectors, deadline);
        for (;;) {
          await new Promise((done) => setTimeout(done, 50));
          const next = await readRectsBy(statePage, selectors, deadline);
          if (next === last) return JSON.parse(last).rects;
          last = next;
          if (Date.now() >= until) throw new Error("layout did not settle in " + limitMs + "ms");
        }
      }

      async function runOneState(statePage, st, reload, routeEnd) {
        const result = { name: st.name };
        const deadline = Math.min(routeEnd, Date.now() + STATE_LIMIT_MS);
        const waitFor = (selector, what) => bounded(
          () => statePage.waitForSelector(selector, { visible: true, timeout: innerMs(st.timeoutMs, deadline) }),
          st.timeoutMs, deadline, what);
        try {
          await bounded(() => reload(innerMs(STATE_RELOAD_MS, deadline)), STATE_RELOAD_MS, deadline, "reload");
          if (st.click) {
            await waitFor(st.click, "click target");
            // Click scrolls the target into view; do it first so a fixed or sticky
            // watched element is not measured before the scroll and after it.
            await bounded(() => statePage.evaluate((selector) => {
              const target = document.querySelector(selector);
              if (target) target.scrollIntoView({ block: "center", inline: "center" });
            }, st.click), st.timeoutMs, deadline, "scroll into view");
          }
          const before = await settledRects(statePage, st.watch, st.timeoutMs, deadline);
          if (st.click) await bounded(() => statePage.click(st.click), st.timeoutMs, deadline, "click");
          if (st.ready) await waitFor(st.ready, "ready element");
          result.after = await settledRects(statePage, st.watch, st.timeoutMs, deadline);
          result.before = before;
          result.scrollWidth = await bounded(() => statePage.evaluate(() => document.documentElement.scrollWidth), st.timeoutMs, deadline, "width read");
        } catch (err) {
          result.error = String(err);
          result.hung = err && err.hung === true;
        }
        return result;
      }

      async function runStates(statePage, states, reload, routeEnd) {
        // A beforeunload prompt is accepted so the next reload can leave the
        // page; every other dialog is dismissed.
        const onDialog = (dialog) => {
          const settle = dialog.type() === "beforeunload" ? dialog.accept() : dialog.dismiss();
          Promise.resolve(settle).catch(() => {});
        };
        statePage.on("dialog", onDialog);
        const results = [];
        let hung = false;
        try {
          for (const st of states) {
            if (Date.now() >= routeEnd) {
              results.push({ name: st.name, error: "state budget was used up" });
              continue;
            }
            // A timed-out step may still be running in the page (a click, a
            // navigation). The next state would reload on top of it, so the
            // rest of the route stops here instead.
            if (hung) {
              results.push({ name: st.name, error: "skipped: an earlier state hung and may still be running" });
              continue;
            }
            const result = await runOneState(statePage, st, reload, routeEnd);
            hung = result.hung === true;
            delete result.hung;
            results.push(result);
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
