# frozen_string_literal: true

require "pathname"
require_relative "test_helpers"
require_relative "#{File.expand_path('../scripts', __dir__)}/color_check"

class ColorCheckTest < Minitest::Test
  include SkillTempHome

  def with_dir
    Dir.mktmpdir do |dir|
      yield dir
    end
  end

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  FOUR_COLOR_TOKENS = <<~CSS
    :root,
    :root[data-theme="light"] {
      --cream: #f6efe0;
      --plum: #24122a;
      --lilac: #a070c8;
      --pink: #f2c4c4;
      --bg: var(--cream);
      --text: var(--plum);
    }

    :root[data-theme="dark"] {
      --cream: #f6efe0;
      --plum: #24122a;
      --lilac: #a070c8;
      --pink: #f2c4c4;
      --bg: var(--plum);
      --text: var(--cream);
    }
  CSS

  # Each row states what CSS itself computes, not what the checker does
  # today; pending: true marks a row the current code still fails. Expected
  # ratios come from an independent WCAG calculation, never from the checker.
  CORPUS = [
    # :comments
    { id: "comments-block-comment-not-mid-value", cls: :comments,
      files: { "tokens.css" => ":root{--bg:#fff;/* --text: #fff; */--text:#000;}" },
      palette: [ "#fff", "#000" ],
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "comments-scss-line-comment", cls: :comments,
      files: { "tokens.scss" => ":root {\n  --bg: #fff; // --text: #333;\n  --text: #000;\n}\n" },
      palette: [ "#fff", "#000" ],
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "comments-block-comment-with-brace", cls: :comments,
      files: { "tokens.css" => ":root{--bg:#fff; /* } */ --text:#777;}" },
      contrast: [ [ "light", "--text", "--bg", 4.48 ] ],
      pending: false },

    # :strings
    { id: "strings-semicolon-and-brace-in-value-string", cls: :strings,
      files: { "tokens.css" => ":root {\n  --bg: #fff;\n  --label: \"a;b}c\";\n  --text: #000;\n}\n" },
      palette: [ "#fff", "#000" ],
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },

    # :block_nesting
    { id: "block-nesting-media-min-width-unsupported", cls: :block_nesting,
      files: { "tokens.css" => "@media (min-width: 40em) { :root { --text: #777 } }" },
      contrast: [ [ "unsupported", "--text", nil, :unresolved, "unsupported theme context" ] ],
      pending: false },
    { id: "block-nesting-layer-base-light", cls: :block_nesting,
      files: { "tokens.css" => "@layer base { :root { --bg:#fff; --text:#000 } }" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },

    # :theme_contexts
    { id: "round4-root-defaults-not-light-only", cls: :theme_contexts,
      files: { "tokens.css" => ':root{--bg:#000} :root[data-theme="light"]{--bg:#fff;--text:#000} :root[data-theme="dark"]{--text:#fff}' },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "repro1-media-dark-override", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000;--a:#123;} @media (prefers-color-scheme: dark){:root{--bg:#000;--text:#777;}}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 4.69 ] ],
      pending: false },
    { id: "repro2-separate-theme-names-not-collapsed", cls: :theme_contexts,
      files: { "tokens.css" => ':root{--bg:#fff;--text:#777;} :root[data-theme="dark"]{--bg:#fff;--text:#777;}' },
      contrast: [ [ "light", "--text", "--bg", 4.48 ], [ "dark", "--text", "--bg", 4.48 ] ],
      pending: false },
    { id: "repro3-dim-theme-not-inherited-from-light", cls: :theme_contexts,
      files: { "tokens.css" => ':root{--bg:#fff;--text:#000} :root[data-theme="dim"]{--bg:#333;--text:#000}' },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dim", "--text", "--bg", 1.66 ] ],
      pending: false },
    { id: "repro8-shadcn-bare-dark-class", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000} .dark{--bg:#000;--text:#fff}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "theme-bare-data-theme-attr-with-base", cls: :theme_contexts,
      files: { "tokens.css" => ':root{--bg:#000;--text:#000} [data-theme="dark"]{--text:#fff}' },
      contrast: [ [ "light", "--text", "--bg", 1.0 ], [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "theme-html-dark-class", cls: :theme_contexts,
      files: { "tokens.css" => "html{--bg:#fff;--text:#000} html.dark{--bg:#000;--text:#fff}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "theme-root-dark-class", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000} :root.dark{--bg:#000;--text:#fff}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "theme-bare-dark-with-color-scheme-decl", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#000;--text:#000} .dark{--text:#fff; color-scheme: dark}" },
      contrast: [ [ "light", "--text", "--bg", 1.0 ], [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "theme-card-block-not-custom-property-only-unsupported", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#fff} .card{color:red; --text:#000}" },
      contrast: [ [ "unsupported", "--text", nil, :unresolved, "not a recognized theme context" ] ],
      findings: [ [ "tokens.css", 1, "literal" ] ],
      pending: false },
    { id: "repro9-html-data-theme-dark-root-form", cls: :theme_contexts,
      files: { "tokens.css" => 'html[data-theme="dark"]{--bg:#000;--text:#fff}' },
      contrast: [ [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "theme-site-pattern-media-dark-not-plus-explicit-dark-collapse", cls: :theme_contexts,
      files: { "tokens.css" => "@media (prefers-color-scheme: dark) { :root:not([data-theme=\"light\"]) { --bg: #000; --text: #fff; } }\n:root[data-theme=\"dark\"] { --bg: #000; --text: #fff; }\n" },
      contrast: [ [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "theme-split-root-rules-combine", cls: :theme_contexts,
      files: { "tokens.css" => ":root { --cream: #ffffff; --plum: #000000; } :root { --bg: var(--cream); } :root { --text: var(--plum); }" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "theme-four-color-tokens-fixture", cls: :theme_contexts,
      files: { "tokens.css" => FOUR_COLOR_TOKENS },
      palette: [ "#f6efe0", "#24122a", "#a070c8", "#f2c4c4" ],
      pending: false },

    # :termination
    { id: "termination-repro5-no-mid-semicolons", cls: :termination,
      files: { "tokens.css" => ":root{--a:#123;--bg:#fff;--text:#000}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "termination-last-declaration-keeps-authored", cls: :termination,
      files: { "tokens.css" => ":root { --bg: #fff; --last: #555 }\n.hero { color: #abcdef; }\n" },
      palette: [ "#fff", "#555" ],
      findings: [ [ "tokens.css", 2, "literal" ] ],
      pending: false },
    { id: "termination-multiline-exempt-correct-lines", cls: :termination,
      files: { "tokens.css" => ":root {\n  --cream: #f6efe0;\n  --plum: #24122a;\n}\n:root {\n  --brand:\n    #123456;\n}\n.x { color: #abcdef; }\n" },
      palette: [ "#f6efe0", "#24122a", "#123456" ],
      findings: [ [ "tokens.css", 9, "literal" ] ],
      pending: false },

    # :color_syntax
    { id: "color-syntax-named-white-black", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:white;--text:black}" },
      palette: [ "white", "black" ],
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "color-syntax-rgb-space-and-comma", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:rgb(255 255 255);--text:rgb(0,0,0)}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "color-syntax-hsl-space-percent", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:hsl(0 0% 100%);--text:#000000}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "color-syntax-important-resolves", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:#fff !important;--text:#000}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "color-syntax-oklch-unresolved-reason", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:#fff;--text:oklch(0.5 0.1 90)}" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "oklch" ] ],
      pending: false },

    # :value_functions
    { id: "round4-color-mix-var-arguments", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000;--text-muted:color-mix(in srgb, var(--text) 60%, var(--bg))}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "light", "--text-muted", "--bg", 5.74 ] ],
      pending: false },
    { id: "repro16-color-mix-var-second-stop", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000;--text-muted:color-mix(in srgb, var(--text), var(--bg) 40%)}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "light", "--text-muted", "--bg", 5.74 ] ],
      pending: false },
    { id: "repro15-var-fallback-missing-token", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#fff;--text: var(--missing, #000)}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "value-functions-var-cycle-no-raise", cls: :value_functions,
      files: { "tokens.css" => ":root { --bg: #fff; --text: var(--text); --a: var(--b); --b: var(--a); }" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "cycle" ] ],
      pending: false },
    { id: "value-functions-color-mix-oklch-unresolved", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#fff;--text:color-mix(in oklch, white 50%, black 50%)}" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "oklch" ] ],
      pending: false },
    { id: "value-functions-color-mix-transparent-matches-today", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#fff;--x:#000000;--text:color-mix(in srgb, var(--x) 12%, transparent)}" },
      contrast: [ [ "light", "--text", "--bg", 1.32 ] ],
      pending: false },

    # :pairing
    { id: "pairing-base-text-pairs-with-base", cls: :pairing,
      files: { "tokens.css" => ":root{--gold-btn:#000000;--gold-btn-text:#ffffff;--bg:#000000}" },
      contrast: [ [ "light", "--gold-btn-text", "--gold-btn", 21.0 ] ],
      pending: false },
    { id: "pairing-exact-bg-preferred-over-surface-bg-segment", cls: :pairing,
      files: { "tokens.css" => ":root {\n  --surface-bg: #000000;\n  --bg: #ffffff;\n  --ink: #000000;\n}\n" },
      contrast: [ [ "light", "--ink", "--bg", 21.0 ] ],
      pending: false },
    { id: "pairing-context-and-ink-like-not-text-roles", cls: :pairing,
      files: { "tokens.css" => ":root {\n  --bg: #ffffff;\n  --context: #112233;\n  --ink-like: #445566;\n  --ink: #000000;\n}\n" },
      contrast: [ [ "light", "--ink", "--bg", 21.0 ] ],
      pending: false },

    # :false_positives
    { id: "fp-id-selector-var-text", cls: :false_positives,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000}", "extra.css" => "#feed{color:var(--text)}" },
      findings: [],
      pending: false },
    { id: "fp-id-selector-cafe-empty-block", cls: :false_positives,
      files: { "extra.css" => "#cafe .x{}" },
      findings: [],
      pending: false },
    { id: "fp-exempt-keywords", cls: :false_positives,
      files: { "extra.css" => ".x{color:transparent; fill:currentColor; border-color:inherit; outline:none}" },
      findings: [],
      pending: false },
    { id: "fp-content-string-red-and-var-red", cls: :false_positives,
      files: { "extra.css" => '.x{content:"red"; color:var(--red)}' },
      findings: [],
      pending: false },
    { id: "fp-red-selector-empty", cls: :false_positives,
      files: { "extra.css" => ".red{}" },
      findings: [],
      pending: false },
    { id: "fp-js-identifier-and-red-alert-string", cls: :false_positives,
      files: { "extra.js" => "const red = getColor();\nconst msg = \"Red alert\";\n" },
      findings: [],
      pending: false },
    { id: "fp-mdx-prose-red-button", cls: :false_positives,
      files: { "extra.mdx" => "the red button\n" },
      findings: [],
      pending: false },
    { id: "repro10-query-selector-cafe", cls: :false_positives,
      files: { "extra.js" => "document.querySelector('#cafe');\n" },
      findings: [],
      pending: false },
    { id: "fp-link-with-hex-fragment", cls: :false_positives,
      files: { "extra.js" => "const link = '/page#feed';\n" },
      findings: [],
      pending: false },
    { id: "fp-bare-three-digit-hex-in-string", cls: :false_positives,
      files: { "extra.js" => "const a = '#add';\n" },
      findings: [],
      pending: false },
    { id: "repro11-url-svg-fragment", cls: :false_positives,
      files: { "extra.css" => ".x { background: url(img.svg#a1b2c3); }\n" },
      findings: [],
      pending: false },
    { id: "repro12-mdx-issue-numbers", cls: :false_positives,
      files: { "extra.mdx" => "See issue #123 and #add\n" },
      findings: [],
      pending: false },
    { id: "fp-html-entity-not-literal", cls: :false_positives,
      files: { "extra.tsx" => "const Arrow = () => <span>&#8599;</span>;\n" },
      findings: [],
      pending: false },
    { id: "fp-href-fragment", cls: :false_positives,
      files: { "extra.html" => '<a href="#fade">x</a>' },
      findings: [],
      pending: false },

    # :stray_scope
    { id: "stray-button-jsx-four-literals", cls: :stray_scope,
      files: { "src/Button.jsx" => "const a = \"#ff0000\";\nconst b = \"rgb(1,2,3)\";\nconst c = \"hsl(0, 0%, 0%)\";\nconst d = \"oklch(0.5 0.1 90)\";\n" },
      findings: [ [ "src/Button.jsx", 1, "literal" ], [ "src/Button.jsx", 2, "literal" ], [ "src/Button.jsx", 3, "literal" ], [ "src/Button.jsx", 4, "literal" ] ],
      pending: false },
    { id: "stray-html-style-fill-stroke-attrs", cls: :stray_scope,
      files: { "extra.html" => '<div style="color:#123456"></div><svg><path fill="#abc"/><path stroke="rgb(1,2,3)"/></svg>' },
      findings: [ [ "extra.html", 1, "literal" ], [ "extra.html", 1, "literal" ], [ "extra.html", 1, "literal" ] ],
      pending: false },
    { id: "stray-css-named-color-literals", cls: :stray_scope,
      files: { "extra.css" => ".x{color:red}\n.y{background:Navy}\n" },
      findings: [ [ "extra.css", 1, "literal" ], [ "extra.css", 2, "literal" ] ],
      pending: false },
    { id: "stray-fill-red-style-white-js-teal", cls: :stray_scope,
      files: { "extra.html" => '<svg><path fill="red"/></svg><div style="color: white"></div>', "extra.js" => "const c = \"teal\";\n" },
      findings: [ [ "extra.html", 1, "literal" ], [ "extra.html", 1, "literal" ], [ "extra.js", 1, "literal" ] ],
      pending: false },
    { id: "stray-fill-none-gives-none", cls: :stray_scope,
      files: { "extra.html" => '<svg><path fill="none"/></svg>' },
      findings: [],
      pending: false },
    { id: "stray-js-object-color-hex3", cls: :stray_scope,
      files: { "extra.js" => "const s = { color: '#fff' };\n" },
      findings: [ [ "extra.js", 1, "literal" ] ],
      pending: false },
    { id: "stray-jsx-style-object-bg-color-hex4", cls: :stray_scope,
      files: { "extra.jsx" => "const x = <div style={{ backgroundColor: '#cafe' }}/>;\n" },
      findings: [ [ "extra.jsx", 1, "literal" ] ],
      pending: false },
    { id: "stray-js-const-hex6-string", cls: :stray_scope,
      files: { "extra.js" => "const x = '#123456';\n" },
      findings: [ [ "extra.js", 1, "literal" ] ],
      pending: false },
    { id: "stray-vue-style-block-true-line", cls: :stray_scope,
      files: { "extra.vue" => "<template><div/></template>\n<style>\n.x { color: #abcdef; }\n</style>\n" },
      findings: [ [ "extra.vue", 3, "literal" ] ],
      pending: false },
    { id: "stray-tailwind-classname-and-apply", cls: :stray_scope,
      files: { "extra.jsx" => "const x = <div className=\"bg-slate-100\"/>;\n", "extra.css" => "@apply text-blue-600;\n" },
      findings: [ [ "extra.jsx", 1, "tailwind" ], [ "extra.css", 1, "tailwind" ] ],
      pending: false },
    { id: "stray-gradient-in-css-value", cls: :stray_scope,
      files: { "extra.css" => ".hero { background: linear-gradient(to right, #ff0000, #0000ff); }\n" },
      findings: [ [ "extra.css", 1, "literal" ], [ "extra.css", 1, "literal" ], [ "extra.css", 1, "gradient" ] ],
      pending: false },

    # :past_findings, one row per review finding already fixed on this
    # branch (the id carries the fixing commit), so a rewrite cannot
    # reintroduce one. The two open round-4 findings live under their own
    # classes as round4- rows.
    { id: "past-4a0c408-inherit-base-root-tokens", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --cream: #ffffff;\n  --plum: #000000;\n  --bg: var(--cream);\n  --text: var(--plum);\n}\n\n:root[data-theme=\"dark\"] {\n  --bg: var(--plum);\n  --text: var(--cream);\n}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "past-a55862c-composite-eight-digit-alpha-hex", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --bg: #ffffff;\n  --text: #00000000;\n}\n" },
      contrast: [ [ "light", "--text", "--bg", 1.0 ] ],
      pending: false },
    { id: "past-9345400-anchor-text-name-to-segments", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --bg: #ffffff;\n  --pink: #f2c4c4;\n  --ink: #000000;\n}\n" },
      contrast: [ [ "light", "--ink", "--bg", 21.0 ] ],
      pending: false },
    { id: "past-e24f742-scan-ordinary-rules-in-token-file", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --bg: #ffffff;\n  --text: #000000;\n}\n.hero { background: linear-gradient(#fff, #000); color: #123456; }\n" },
      findings: [ [ "tokens.css", 5, "gradient" ], [ "tokens.css", 5, "literal" ], [ "tokens.css", 5, "literal" ], [ "tokens.css", 5, "literal" ] ],
      pending: false },
    { id: "past-a9e8434-prefer-exact-background-role-name", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --background-accent: #000000;\n  --bg: #ffffff;\n  --ink: #000000;\n}\n" },
      contrast: [ [ "light", "--ink", "--bg", 21.0 ] ],
      pending: false },
    { id: "past-016f07d-recognize-four-digit-hex", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --bg: #ffff;\n  --text: #000f;\n}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "past-b80c932-exempt-multiline-token-declarations", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --cream: #f6efe0;\n  --plum: #24122a;\n}\n:root {\n  --brand:\n    #123456;\n}\n.x { color: #abcdef; }\n" },
      findings: [ [ "tokens.css", 9, "literal" ] ],
      pending: false },
    { id: "past-a58def4-stop-variable-cycles", cls: :past_findings,
      files: { "tokens.css" => ":root { --bg: #fff; --text: var(--text); --a: var(--b); --b: var(--a); }\n" },
      contrast: [ [ "light", "--text", "--bg", :unresolved ] ],
      pending: false },
    { id: "past-1f3cac0-declaration-boundaries-without-semicolon", cls: :past_findings,
      files: { "tokens.css" => ":root { --bg: #fff; --last: #555 }\n.hero { color: #abcdef; }\n" },
      palette: [ "#fff", "#555" ],
      findings: [ [ "tokens.css", 2, "literal" ] ],
      pending: false },
    { id: "past-e068235-accumulate-repeated-root-rules", cls: :past_findings,
      files: { "tokens.css" => ":root { --cream: #ffffff; --plum: #000000; }\n:root { --bg: var(--cream); }\n:root { --text: var(--plum); }\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "past-567bce1-html-entity-hex-not-literal", cls: :past_findings,
      files: { "extra.tsx" => "const Arrow = () => <span>&#8599;</span>;\nconst style = { color: \"#abc\" };\n" },
      findings: [ [ "extra.tsx", 2, "literal" ] ],
      pending: false },
    { id: "past-567bce1-base-text-pairs-with-matching-base-token", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --btn: #000000;\n  --btn-text: #ffffff;\n  --bg: #000000;\n}\n" },
      contrast: [ [ "light", "--btn-text", "--btn", 21.0 ] ],
      pending: false }
  ].freeze

  def relative_path(path, dir)
    Pathname.new(path).relative_path_from(Pathname.new(dir)).to_s
  end

  def contrast_reason(pair)
    pair.respond_to?(:reason) ? pair.reason : nil
  end

  def contrast_match?(pair, expected_row)
    theme, text_token, bg_token, *rest = expected_row
    return false unless pair.theme == theme && pair.text_token == text_token && pair.bg_token == bg_token

    if rest.first == :unresolved
      !pair.resolved && (rest[1].nil? || contrast_reason(pair).to_s.include?(rest[1]))
    else
      pair.resolved && (rest.first.nil? || (pair.ratio - rest.first).abs < 0.01)
    end
  end

  def describe_pairs(pairs)
    pairs.map { |p| [ p.theme, p.text_token, p.bg_token, p.ratio, p.resolved ] }.inspect
  end

  # Each expected row consumes one matching pair, so duplicates must appear
  # as many times as expected and nothing may be left over.
  def assert_contrast_rows(row, pairs)
    remaining = pairs.dup
    row[:contrast].each do |expected_row|
      found_index = remaining.find_index { |pair| contrast_match?(pair, expected_row) }
      assert found_index, "expected contrast row #{expected_row.inspect} not found for #{row[:id]} " \
                          "(actual: #{describe_pairs(remaining)})"
      remaining.delete_at(found_index)
    end
    assert_empty remaining, "unexpected extra contrast rows for #{row[:id]}: #{describe_pairs(remaining)}"
  end

  def assert_corpus_row(row, report, dir)
    if row[:palette]
      actual = report.palette ? report.palette.authored.map { |a| a[:value] }.sort : []
      assert_equal row[:palette].sort, actual, "palette mismatch for #{row[:id]}"
    end

    assert_contrast_rows(row, report.contrast) if row[:contrast]
    return unless row[:findings]

    actual = report.findings.map { |f| [ relative_path(f.file, dir), f.line, f.kind ] }.sort
    assert_equal row[:findings].sort, actual, "findings mismatch for #{row[:id]}"
  end

  CORPUS.each do |row|
    define_method("test_corpus_#{row[:id].tr('-', '_')}") do
      skip "pending: #{row[:cls]}" if row[:pending]

      with_dir do |dir|
        row[:files].each { |rel, content| write(dir, rel, content) }
        report = ColorCheck.run(dir)
        assert_corpus_row(row, report, dir)
      end
    end
  end

  def test_four_authored_colors_reassigned_across_themes_count_as_four
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir)
      assert_equal 4, report.palette.authored.size
    end
  end

  def test_error_token_recognised_and_excluded_sixth_color_reported_above_target
    with_dir do |dir|
      css = FOUR_COLOR_TOKENS.sub("--pink: #f2c4c4;", "--pink: #f2c4c4;\n  --error: #ff0000;\n  --extra: #123456;")
      write(dir, "tokens.css", css)
      report = ColorCheck.run(dir)
      assert report.palette.error_token
      assert_equal 5, report.palette.authored.size
      refute report.palette.authored.any? { |a| a[:names].include?("--error") }
    end
  end

  def test_color_mix_and_var_values_count_as_derived
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir)
      assert_operator report.palette.derived, :>, 0
    end
  end

  def test_literal_colors_in_component_file_reported_with_file_and_line
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "src/Button.jsx", <<~JSX)
        const a = "#ff0000";
        const b = "rgb(1,2,3)";
        const c = "hsl(0, 0%, 0%)";
        const d = "oklch(0.5 0.1 90)";
      JSX
      report = ColorCheck.run(dir)
      literal_findings = report.findings.select { |f| f.kind == "literal" }
      assert_equal 4, literal_findings.size
      assert literal_findings.all? { |f| f.file.end_with?("Button.jsx") }
      assert_equal [ 1, 2, 3, 4 ], literal_findings.map(&:line).sort
    end
  end

  def test_tailwind_classes_reported_and_semantic_class_not_reported
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "src/Card.jsx", <<~JSX)
        <div className="bg-slate-100 text-blue-600 bg-primary">hi</div>
      JSX
      report = ColorCheck.run(dir)
      tailwind_findings = report.findings.select { |f| f.kind == "tailwind" }
      matches = tailwind_findings.flat_map { |f| f.text.scan(ColorCheck::TAILWIND) }
      assert_includes matches, "bg-slate-100"
      assert_includes matches, "text-blue-600"
      refute_includes matches, "bg-primary"
    end
  end

  def test_gradient_reported
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "src/hero.css", ".hero { background: linear-gradient(to right, red, blue); }")
      report = ColorCheck.run(dir)
      assert report.findings.any? { |f| f.kind == "gradient" }
    end
  end

  def test_node_modules_and_dist_are_skipped
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "node_modules/pkg/index.css", ".x { color: #ff0000; }")
      write(dir, "dist/bundle.css", ".y { color: #00ff00; }")
      report = ColorCheck.run(dir)
      assert report.findings.none? { |f| f.file.include?("node_modules") }
      assert report.findings.none? { |f| f.file.include?("/dist/") }
    end
  end

  def test_tokens_flag_overrides_detection
    with_dir do |dir|
      write(dir, "decoy.css", ":root { --a: #111111; --b: #222222; --c: #333333; --d: #444444; --e: #555555; }")
      override_path = write(dir, "real-tokens.css", FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir, tokens_override: override_path)
      assert_equal override_path, report.palette.file
      assert_equal 4, report.palette.authored.size
    end
  end

  def test_default_exit_is_zero_even_with_findings
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "src/Button.jsx", 'const a = "#ff0000";')
      report = ColorCheck.run(dir, strict: false)
      assert_equal 0, report.exit_code
    end
  end

  def test_multiline_token_declaration_is_exempt_and_lines_stay_correct
    with_dir do |dir|
      css = FOUR_COLOR_TOKENS + ":root {\n  --brand:\n    #123456;\n}\n.x { color: #abcdef; }\n"
      write(dir, "tokens.css", css)
      report = ColorCheck.run(dir, tokens_override: File.join(dir, "tokens.css"))
      literals = report.findings.select { |f| f.kind == "literal" }
      assert_equal 1, literals.size
      assert_includes literals.first.text, "#abcdef"
      assert_equal css.lines.index { |l| l.include?("#abcdef") } + 1, literals.first.line
    end
  end

  def test_strict_exits_one_with_findings_and_zero_without
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "src/Button.jsx", 'const a = "#ff0000";')
      with_findings = ColorCheck.run(dir, strict: true)
      assert_equal 1, with_findings.exit_code
    end

    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      without_findings = ColorCheck.run(dir, strict: true)
      assert_equal 0, without_findings.exit_code
    end
  end

  def test_contrast_black_on_white_is_21
    with_dir do |dir|
      write(dir, "tokens.css", <<~CSS)
        :root {
          --bg: #ffffff;
          --text: #000000;
        }
      CSS
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.text_token == "--text" }
      refute_nil pair
      assert pair.resolved
      assert_in_delta 21.0, pair.ratio, 0.01
    end
  end

  def test_contrast_composites_eight_digit_alpha_hex
    with_dir do |dir|
      write(dir, "tokens.css", <<~CSS)
        :root {
          --bg: #ffffff;
          --text: #00000000;
        }
      CSS
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.text_token == "--text" }
      refute_nil pair
      assert_in_delta 1.0, pair.ratio, 0.01
      refute pair.passes_body
    end
  end

  def test_contrast_composites_four_digit_alpha_hex
    with_dir do |dir|
      write(dir, "tokens.css", <<~CSS)
        :root {
          --bg: #ffff;
          --text: #000f;
        }
      CSS
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.text_token == "--text" }
      refute_nil pair
      assert pair.resolved
      assert_in_delta 21.0, pair.ratio, 0.01
    end
  end

  def test_contrast_color_mix_pair_resolves
    with_dir do |dir|
      write(dir, "tokens.css", <<~CSS)
        :root {
          --bg: #ffffff;
          --plum: #24122a;
          --text: color-mix(in srgb, var(--plum) 100%, transparent);
        }
      CSS
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.text_token == "--text" }
      refute_nil pair
      assert pair.resolved
    end
  end

  def test_dark_theme_override_resolves_against_root_palette_tokens
    with_dir do |dir|
      write(dir, "tokens.css", <<~CSS)
        :root {
          --cream: #ffffff;
          --plum: #000000;
          --bg: var(--cream);
          --text: var(--plum);
        }

        :root[data-theme="dark"] {
          --bg: var(--plum);
          --text: var(--cream);
        }
      CSS
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.theme == "dark" && c.text_token == "--text" }
      refute_nil pair
      assert pair.resolved
      assert_in_delta 21.0, pair.ratio, 0.01
    end
  end

  def test_contrast_accumulates_split_root_rules
    with_dir do |dir|
      write(dir, "tokens.css", <<~CSS)
        :root { --cream: #ffffff; --plum: #000000; }
        :root { --bg: var(--cream); }
        :root { --text: var(--plum); }
      CSS
      report = ColorCheck.run(dir)
      pairs = report.contrast.select { |c| c.text_token == "--text" }
      assert_equal 1, pairs.size
      assert pairs.first.resolved
      assert_in_delta 21.0, pairs.first.ratio, 0.01
    end
  end

  def test_contrast_unresolvable_pair_listed_as_unresolved
    with_dir do |dir|
      write(dir, "tokens.css", <<~CSS)
        :root {
          --bg: #ffffff;
          --text: oklch(0.5 0.1 90);
        }
      CSS
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.text_token == "--text" }
      refute_nil pair
      refute pair.resolved
    end
  end

  def test_html_entity_hex_is_not_a_literal_finding
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "src/Arrow.tsx", <<~TSX)
        const Arrow = () => <span>&#8599;</span>;
        const style = { color: "#abc" };
      TSX
      report = ColorCheck.run(dir)
      literal_findings = report.findings.select { |f| f.kind == "literal" }
      assert_equal 1, literal_findings.size
      refute literal_findings.any? { |f| f.text.include?("&#8599;") }
      assert literal_findings.any? { |f| f.text.include?("#abc") }
    end
  end

  def test_contrast_text_token_paired_with_matching_base_token
    with_dir do |dir|
      write(dir, "tokens.css", <<~CSS)
        :root {
          --btn: #000000;
          --btn-text: #ffffff;
          --bg: #000000;
        }
      CSS
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.text_token == "--btn-text" }
      refute_nil pair
      assert_equal "--btn", pair.bg_token
      assert pair.resolved
      assert_in_delta 21.0, pair.ratio, 0.01
      assert pair.passes_body
    end
  end

  def test_contrast_ignores_palette_names_containing_role_substrings
    with_dir do |dir|
      write(dir, "tokens.css", ":root {\n  --bg: #ffffff;\n  --pink: #f2c4c4;\n  --ink: #000000;\n}\n")
      report = ColorCheck.run(dir)
      tokens = report.contrast.map(&:text_token)
      refute_includes tokens, "--pink"
      assert_includes tokens, "--ink"
    end
  end

  def test_contrast_prefers_exact_background_role_name
    with_dir do |dir|
      write(dir, "tokens.css", ":root {\n  --background-accent: #000000;\n  --bg: #ffffff;\n  --ink: #000000;\n}\n")
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.text_token == "--ink" }
      refute_nil pair
      assert_equal "--bg", pair.bg_token
      assert_in_delta 21.0, pair.ratio, 0.01
    end
  end

  def test_json_output_parses
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir)
      parsed = JSON.parse(ColorCheck.to_json_report(report))
      assert parsed.key?("palette")
      assert parsed.key?("findings")
      assert parsed.key?("contrast")
      assert parsed.key?("exit_code")
    end
  end

  def test_empty_directory_reports_no_palette_found_and_exits_zero
    with_dir do |dir|
      report = ColorCheck.run(dir)
      assert_nil report.palette
      assert_equal 0, report.exit_code
      assert_includes ColorCheck.render(report), "no palette found"
    end
  end

  def test_ordinary_rules_in_token_file_still_scanned
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS + ".hero { background: linear-gradient(#fff, #000); color: #123456; }\n")
      report = ColorCheck.run(dir, strict: true)
      kinds = report.findings.map(&:kind)
      assert_includes kinds, "gradient"
      assert_includes kinds, "literal"
      assert report.findings.none? { |f| f.text.include?("--cream") }
      assert_equal 1, report.exit_code
    end
  end

  def test_var_cycle_resolves_to_nil_instead_of_crashing
    with_dir do |dir|
      write(dir, "tokens.css", ":root { --bg: #fff; --text: var(--text); --a: var(--b); --b: var(--a); }\n")
      report = ColorCheck.run(dir)
      assert_equal 0, report.exit_code
    end
  end

  def test_final_declaration_without_semicolon_stops_at_brace
    with_dir do |dir|
      write(dir, "tokens.css", ":root { --bg: #fff; --last: #555 }\n.hero { color: #abcdef; }\n")
      report = ColorCheck.run(dir, tokens_override: File.join(dir, "tokens.css"))
      assert report.findings.any? { |f| f.text.include?("#abcdef") }
      assert(report.palette.authored.any? { |a| a[:names].include?("--last") })
    end
  end
end
