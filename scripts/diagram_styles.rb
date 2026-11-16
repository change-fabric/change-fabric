# frozen_string_literal: true

require "json"
require_relative "browserless_js"

# Computed styles for the provider icon checks, read from the pinned
# Chromium the lint already starts for text measurement. Chromium is the
# only CSS parser: the checks never resolve a selector, a cascade, or a
# var() themselves. For each color scheme (prefers-color-scheme light and
# dark) the page reports every element's computed paint, the diagram's
# --bg, and, per icon, each property where the icon as placed renders
# differently from the same svg.icon alone in a shadow root, which no
# diagram stylesheet can reach.
module DiagramStyles
  SCHEMES = %w[light dark].freeze
  PAINT = %w[fill stroke opacity fill-opacity stroke-opacity display visibility filter].freeze

  # One scheme's answer. `paint` and `alpha` are indexed like
  # Document#all_elements; `alpha` is each element's effective opacity, the
  # product of opacity up through every ancestor. `shown` has one entry per
  # svg.icon: its rendered box and whether anything hides it.
  Scheme = Data.define(:paint, :alpha, :bg, :recolored, :shown)

  # `names` is the element order the browser saw, checked against the
  # parsed document before any index is trusted.
  Result = Data.define(:names, :schemes) do
    def aligned?(doc) = names == doc.all_elements.map(&:name)
    def [](scheme) = schemes.fetch(scheme)
  end

  module_function

  def js_module(svg)
    html = "<!doctype html><html><body style=\"margin:0\">#{svg}</body></html>"
    <<~JS
      export default async ({ page }) => {
        #{BrowserlessJs.inline_html_js(html)}
        const PAINT = #{JSON.generate(PAINT)};
        const read = () => page.evaluate((PAINT) => {
          const root = document.querySelector("svg");
          const els = [ root, ...root.querySelectorAll("*") ];
          const paintOf = (el) => {
            const cs = getComputedStyle(el);
            const out = {};
            for (const p of PAINT) out[p] = cs.getPropertyValue(p);
            return out;
          };
          const probe = document.createElementNS("http://www.w3.org/2000/svg", "rect");
          probe.setAttribute("style", "fill: var(--bg)");
          root.append(probe);
          const bg = getComputedStyle(probe).fill;
          probe.remove();

          const alpha = els.map((el) => {
            let a = 1;
            for (let n = el; n && n.nodeType === 1; n = n.parentElement) a *= parseFloat(getComputedStyle(n).opacity || "1");
            return a;
          });
          const hidden = (el) => {
            for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
              const cs = getComputedStyle(n);
              if (cs.display === "none") return "display: none";
            }
            return getComputedStyle(el).visibility !== "visible" ? "visibility: " + getComputedStyle(el).visibility : null;
          };
          const shown = [];
          const recolored = [];
          els.forEach((el, index) => {
            if (el === root || el.localName !== "svg" || !el.classList.contains("icon")) return;
            // A nested svg's client rect follows its children, so the CSS
            // viewport size is read too; either at zero means nothing shows.
            const box = el.getBoundingClientRect();
            const cs = getComputedStyle(el);
            const w = Math.min(box.width, parseFloat(cs.width));
            const h = Math.min(box.height, parseFloat(cs.height));
            shown.push({ icon: index, w: Number.isNaN(w) ? box.width : w, h: Number.isNaN(h) ? box.height : h,
                         alpha: alpha[index], hidden: hidden(el) });
            const host = document.createElement("div");
            document.body.append(host);
            const clone = el.cloneNode(true);
            host.attachShadow({ mode: "open" }).append(clone);
            const placed = [ el, ...el.querySelectorAll("*") ];
            const alone = [ clone, ...clone.querySelectorAll("*") ];
            placed.forEach((p, i) => {
              const a = paintOf(p);
              const b = paintOf(alone[i]);
              for (const prop of PAINT) {
                if (a[prop] !== b[prop]) {
                  recolored.push({ icon: index, el: els.indexOf(p), prop, got: a[prop], want: b[prop] });
                }
              }
            });
            host.remove();
          });
          return { names: els.map((e) => e.localName), paint: els.map(paintOf), alpha, bg, recolored, shown };
        }, PAINT);
        await page.emulateMediaFeatures([ { name: "prefers-color-scheme", value: "light" } ]);
        const light = await read();
        await page.emulateMediaFeatures([ { name: "prefers-color-scheme", value: "dark" } ]);
        const dark = await read();
        return { data: { light, dark }, type: "application/json" };
      };
    JS
  end

  def build(raw)
    schemes = SCHEMES.to_h do |s|
      d = raw.fetch(s)
      [ s.to_sym, Scheme.new(paint: d.fetch("paint"), alpha: d.fetch("alpha"), bg: d["bg"], recolored: d.fetch("recolored"), shown: d.fetch("shown")) ]
    end
    Result.new(names: raw.fetch("light").fetch("names"), schemes: schemes)
  end

  # How visibly an element's fill paints: the fill color's own alpha times
  # fill-opacity times the effective opacity. Zero means it paints nothing.
  def fill_alpha(paint, alpha)
    m = paint["fill"].to_s.match(/\Argba?\(\s*\d+,\s*\d+,\s*\d+(?:,\s*([\d.]+))?\s*\)\z/)
    return 0.0 unless m

    (m[1] ? m[1].to_f : 1.0) * paint["fill-opacity"].to_f * alpha.to_f
  end

  # A computed color as #RRGGBB, or nil for none, a paint server, or a
  # fully transparent color.
  def hex(value)
    m = value.to_s.match(/\Argba?\(\s*(\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\s*\)\z/)
    return nil unless m
    return nil if m[4] && m[4].to_f.zero?

    format("#%02X%02X%02X", m[1].to_i, m[2].to_i, m[3].to_i)
  end
end
