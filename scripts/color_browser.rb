#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'change_docker'
require_relative 'color_math'

# Runs one pinned Chromium (via ChangeDocker's browserless container) as the
# CSS parser for cf:color: it injects the token file's CSS into a page,
# reads the custom-property names the CSSOM actually kept, resolves each
# name's color in four states (light, the .dark class, the data-theme
# attribute, and prefers-color-scheme: dark media), and classifies every
# declared value by the literal colors it carries (alone, as a var()
# fallback, or mixed with a var()) or as derived when it only tracks tokens.
# Whatever the browser accepts is the answer; this module does no CSS
# parsing of its own, and a declaration the browser rejects simply does not
# exist for the checker.
module ColorBrowser
  # Either import_error is true, or (names, ...) carry the browser's answer.
  Result = Data.define(:names, :declared_values, :classified, :states, :import_error)

  module_function

  # Whether docker can run the browser at all; ColorCheck asks before any
  # compile so a missing docker reads as "Docker is required".
  def available?
    ChangeDocker.available?
  end

  def probe(css)
    raw = ChangeDocker.with_browserless(network: nil) { |session| session.run_function(js_module(css)) }
    build_result(raw)
  end

  def build_result(raw)
    if raw['importError']
      return Result.new(names: [], declared_values: {}, classified: {}, states: {},
                         import_error: true)
    end

    names = raw.fetch('names')
    declared_values = raw.fetch('declaredValues')
    classified = raw.fetch('classified').to_h do |value, entry|
      literals = entry.fetch('literals').map { |l| { color: ColorMath.parse(l.fetch('color')), mixed: l.fetch('mixed') } }
      [ value, { kind: entry['kind'], color: ColorMath.parse(entry['color']), literals: } ]
    end
    states = raw.fetch('states').to_h do |variant, map|
      [ variant.to_sym, map.transform_values { |c| ColorMath.parse(c) } ]
    end
    Result.new(names:, declared_values:, classified:, states:, import_error: false)
  end

  # The JS module string posted to browserless's /function endpoint. The
  # token file's raw bytes travel as strict base64 (pack('m0'), no base64
  # gem), so no quoting or encoding of its content happens in Ruby; the page
  # decodes them with TextDecoder, which strips a leading BOM and maps an
  # invalid byte to U+FFFD, as a browser reading the file would.
  def js_module(css_bytes)
    <<~JS
      export default async ({ page }) => {
        const b64 = #{JSON.generate([ css_bytes.to_s.b ].pack('m0'))};
        await page.setContent('<!doctype html><html><head></head><body></body></html>',
          { waitUntil: 'domcontentloaded', timeout: 60000 });

        const setup = await page.evaluate((b64) => {
          const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
          const css = new TextDecoder('utf-8').decode(bytes);
          const style = document.createElement('style');
          style.textContent = css;
          document.head.append(style);

          const hasImport = (rules) => {
            for (const r of rules) {
              if (typeof CSSImportRule !== 'undefined' && r instanceof CSSImportRule) return true;
              if (r.cssRules && hasImport(r.cssRules)) return true;
            }
            return false;
          };
          if (hasImport(style.sheet.cssRules)) return { importError: true };

          const names = new Set();
          const declaredValues = {};
          const walk = (rules) => {
            for (const r of rules) {
              if (r.style) {
                for (const p of r.style) {
                  if (p.startsWith('--')) {
                    names.add(p);
                    (declaredValues[p] ||= []).push(r.style.getPropertyValue(p).trim());
                  }
                }
              }
              if (r.cssRules) walk(r.cssRules);
            }
          };
          walk(style.sheet.cssRules);

          const probe = document.createElement('i');
          document.body.append(probe);
          window.__cfColorProbe = probe;
          window.__cfColorNames = [...names];

          // Resolves one color expression (a var() reference, or a raw
          // declared value) against the current cascade, returning the
          // computed `color(srgb r g b / a)` string or null. Wrapping in
          // color-mix() normalizes every valid color to that one
          // serialization, and setting the parent (body) color to two
          // different sentinels distinguishes a real resolved color from an
          // invalid-at-computed-value-time substitution, which is instead
          // inherited from the parent: a var() to a name the browser
          // dropped, or whose declared value is itself invalid, inherits
          // the sentinel and so differs between the two reads.
          window.__cfColorResolve = (expr) => {
            const sentinels = [ 'rgb(1, 2, 3)', 'rgb(4, 5, 6)' ];
            const vals = sentinels.map((s) => {
              document.body.style.color = s;
              probe.style.color = '';
              probe.style.color = `color-mix(in srgb, ${expr} 100%, transparent 0%)`;
              return getComputedStyle(probe).color;
            });
            document.body.style.color = '';
            return vals[0] === vals[1] ? vals[0] : null;
          };
          window.__cfColorReadState = () => {
            const out = {};
            for (const n of window.__cfColorNames) out[n] = window.__cfColorResolve(`var(${n})`);
            return out;
          };

          // Classifies every distinct declared value in the current state,
          // for color-scheme light and dark (light-dark() picks one side).
          // Each declared name the cascade gave a value here, plus the body
          // color that currentColor inherits, is overridden with a fully
          // transparent black and then a fully transparent white. A value
          // that still reads the same nonzero-alpha color both times holds
          // a literal (a mix of a var() and a literal keeps the literal at
          // reduced alpha); one that tracks the overrides is derived. Only
          // names valid in this state are overridden, so a var() fallback
          // behind an initial or undeclared name still shows its literal.
          const alphaOf = (s) => {
            const m = s.match(/\\/\\s*([\\d.e+-]+)\\s*\\)$/);
            return m ? parseFloat(m[1]) : 1;
          };
          window.__cfColorClassifyState = (values) => {
            probe.style.color = '';
            const computed = getComputedStyle(probe);
            const valid = window.__cfColorNames.filter((n) => computed.getPropertyValue(n) !== '');
            const readWith = (v, s) => {
              for (const n of valid) probe.style.setProperty(n, s);
              document.body.style.color = s;
              probe.style.color = '';
              probe.style.color = `color-mix(in srgb, ${v} 100%, transparent 0%)`;
              const c = getComputedStyle(probe).color;
              for (const n of valid) probe.style.removeProperty(n);
              document.body.style.color = '';
              return c;
            };
            const out = {};
            for (const v of values) {
              const entry = { literals: [], derived: false, normal: null };
              for (const scheme of [ 'light', 'dark' ]) {
                probe.style.colorScheme = scheme;
                const normal = window.__cfColorResolve(v);
                if (scheme === 'light') entry.normal = normal;
                const lit0 = readWith(v, 'rgb(0 0 0 / 0)');
                const lit1 = readWith(v, 'rgb(255 255 255 / 0)');
                if (lit0 === lit1 && alphaOf(lit0) > 0) {
                  entry.literals.push({ color: lit0, mixed: lit0 !== normal });
                } else if (normal !== null && !(lit0 === lit1 && lit0 === normal)) {
                  entry.derived = true;
                }
              }
              probe.style.colorScheme = '';
              probe.style.color = '';
              out[v] = entry;
            }
            return out;
          };

          return { importError: false, names: [...names], declaredValues };
        }, b64);

        if (setup.importError) return { importError: true };

        const values = [ ...new Set(Object.values(setup.declaredValues).flat()) ];
        const read = (vals) => ({ state: window.__cfColorReadState(), cls: window.__cfColorClassifyState(vals) });

        await page.emulateMediaFeatures([ { name: 'prefers-color-scheme', value: 'light' } ]);
        const light = await page.evaluate(read, values);

        const cls = await page.evaluate((vals) => {
          document.documentElement.classList.add('dark');
          const r = { state: window.__cfColorReadState(), cls: window.__cfColorClassifyState(vals) };
          document.documentElement.classList.remove('dark');
          return r;
        }, values);

        const attr = await page.evaluate((vals) => {
          document.documentElement.setAttribute('data-theme', 'dark');
          const r = { state: window.__cfColorReadState(), cls: window.__cfColorClassifyState(vals) };
          document.documentElement.removeAttribute('data-theme');
          return r;
        }, values);

        await page.emulateMediaFeatures([ { name: 'prefers-color-scheme', value: 'dark' } ]);
        const media = await page.evaluate(read, values);

        // Union across the four states: authored when any state found a
        // literal, else derived when any state tracked a token.
        const classified = {};
        for (const v of values) {
          const seen = new Set();
          const literals = [];
          let derived = false;
          for (const r of [ light, cls, attr, media ]) {
            const e = r.cls[v];
            if (e.derived) derived = true;
            for (const l of e.literals) {
              const key = `${l.color}|${l.mixed}`;
              if (seen.has(key)) continue;
              seen.add(key);
              literals.push(l);
            }
          }
          const kind = literals.length > 0 ? 'authored' : (derived ? 'derived' : null);
          classified[v] = { kind, color: light.cls[v].normal, literals };
        }

        return {
          importError: false,
          names: setup.names,
          declaredValues: setup.declaredValues,
          classified,
          states: { light: light.state, class: cls.state, attr: attr.state, media: media.state }
        };
      };
    JS
  end
end
