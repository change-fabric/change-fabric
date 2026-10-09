#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'change_docker'
require_relative 'color_math'

# Runs one pinned Chromium (via ChangeDocker's browserless container) as the
# CSS parser for cf:color: it injects the token file's CSS into a page,
# reads the custom-property names the CSSOM actually kept, resolves each
# name's color in four states (light, the .dark class, the data-theme
# attribute, and prefers-color-scheme: dark media), and classifies every
# declared value as an authored literal or a derived (var()-based) one.
# Whatever the browser accepts is the answer; this module does no CSS
# parsing of its own beyond the lightest text scan (see
# dropped_declarations).
module ColorBrowser
  # Exactly one of docker_unavailable/import_error/(names, ...) applies.
  Result = Data.define(:names, :declared_values, :classified, :states, :import_error, :docker_unavailable)

  module_function

  def probe(css)
    return Result.new(names: [], declared_values: {}, classified: {}, states: {},
                       import_error: false, docker_unavailable: true) unless ChangeDocker.available?

    raw = ChangeDocker.with_browserless(network: nil) { |session| session.run_function(js_module(css)) }
    build_result(raw)
  end

  def build_result(raw)
    if raw['importError']
      return Result.new(names: [], declared_values: {}, classified: {}, states: {},
                         import_error: true, docker_unavailable: false)
    end

    names = raw.fetch('names')
    declared_values = raw.fetch('declaredValues')
    classified = raw.fetch('classified').to_h do |value, entry|
      [ value, { kind: entry['kind'], color: ColorMath.parse(entry['color']) } ]
    end
    states = raw.fetch('states').to_h do |variant, map|
      [ variant.to_sym, map.transform_values { |c| ColorMath.parse(c) } ]
    end
    Result.new(names:, declared_values:, classified:, states:, import_error: false, docker_unavailable: false)
  end

  # Every "--name:" this is fed, scanned out of the raw CSS text (comments
  # blanked first) rather than parsed. A name the browser's CSSOM never
  # reports is one CSS itself dropped (an invalid value, a malformed var()),
  # which is a token-file error; a name the browser DID keep but this scan
  # misses (inside a string, say) only under-reports a heuristic check, never
  # a wrong answer about what the browser actually computed.
  DECL_NAME = /--[A-Za-z0-9_-]+(?=\s*:)/.freeze

  def declared_names(css)
    stripped = css.gsub(%r{/\*.*?\*/}m, ' ')
    stripped.scan(DECL_NAME).uniq
  end

  def dropped_declarations(css, kept_names)
    kept = kept_names.to_set
    declared_names(css).reject { |n| kept.include?(n) }
  end

  # The JS module string posted to browserless's /function endpoint. CSS is
  # passed as a JSON string literal so no quoting of the token file's own
  # content is needed.
  def js_module(css)
    <<~JS
      export default async ({ page }) => {
        const css = #{JSON.generate(css)};
        await page.setContent('<!doctype html><html><head></head><body></body></html>');

        const setup = await page.evaluate((css) => {
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

          return { importError: false, names: [...names], declaredValues };
        }, css);

        if (setup.importError) return { importError: true };

        await page.emulateMediaFeatures([ { name: 'prefers-color-scheme', value: 'light' } ]);
        const light = await page.evaluate(() => window.__cfColorReadState());

        const cls = await page.evaluate(() => {
          document.documentElement.classList.add('dark');
          const r = window.__cfColorReadState();
          document.documentElement.classList.remove('dark');
          return r;
        });

        const attr = await page.evaluate(() => {
          document.documentElement.setAttribute('data-theme', 'dark');
          const r = window.__cfColorReadState();
          document.documentElement.removeAttribute('data-theme');
          return r;
        });

        await page.emulateMediaFeatures([ { name: 'prefers-color-scheme', value: 'dark' } ]);
        const media = await page.evaluate(() => window.__cfColorReadState());

        const classified = await page.evaluate((declaredValues) => {
          const out = {};
          for (const name in declaredValues) {
            for (const v of declaredValues[name]) {
              if (Object.prototype.hasOwnProperty.call(out, v)) continue;

              const hasVar = /var\\(/i.test(v);
              let kind = null;
              let color = null;
              if (!hasVar && CSS.supports('color', v)) {
                color = window.__cfColorResolve(v);
                if (color) kind = 'authored';
              } else if (hasVar) {
                color = window.__cfColorResolve(v);
                if (color) kind = 'derived';
              }
              out[v] = { kind, color };
            }
          }
          return out;
        }, setup.declaredValues);

        return {
          importError: false,
          names: setup.names,
          declaredValues: setup.declaredValues,
          classified,
          states: { light, class: cls, attr, media }
        };
      };
    JS
  end
end
