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
    { id: "adv1-commented-style-block-parsed", cls: :comments,
      files: { "index.html" => "<style>:root{--bg:#fff;--text:#000}</style>\n<!--\n<style>:root{--bg:#000;--text:#111}</style>\n-->\n" },
      palette: [ "#fff", "#000" ],
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
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
    { id: "adv1-layer-precedence-ignored-a", cls: :block_nesting,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000}\n@layer base{:root{--text:#777}}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv1-layer-precedence-ignored-b", cls: :block_nesting,
      files: { "tokens.css" => ":root{--bg:#000;--text:#000}\n@layer theme{.dark{--text:#fff}}\n" },
      contrast: [ [ "light", "--text", "--bg", 1.0 ], [ "dark", "--text", "--bg", 1.0 ] ],
      pending: false },
    { id: "adv1-layer-precedence-ignored-c", cls: :block_nesting,
      files: { "tokens.css" => "@layer a, b;\n@layer b{:root{--bg:#fff;--text:#000}}\n@layer a{:root{--text:#777}}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv1-unsupported-context-label-collision-a", cls: :block_nesting,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000}\n@supports (color: red){:root{--text:#777}}\n@container (min-width: 1px){:root{--text:#111}}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ],
                  [ "unsupported", "--text", nil, :unresolved, "inside @supports (color: red)" ],
                  [ "unsupported", "--text", nil, :unresolved, "inside @container (min-width: 1px)" ] ],
      pending: false },
    { id: "adv1-unsupported-context-label-collision-b", cls: :block_nesting,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000}\n.card p{--text:#777}\n@media print{.card p{--link:#00f}}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ],
                  [ "unsupported", "--text", nil, :unresolved, "not a recognized theme context" ],
                  [ "unsupported", "--link", nil, :unresolved, "inside @media print" ] ],
      pending: false },
    { id: "adv2-imp-layer-reversal", cls: :block_nesting,
      files: { "tokens.css" => ":root{--bg:#ffffff}\n@layer base{:root{--text:#777777 !important}}\n:root{--text:#000000 !important}\n" },
      contrast: [ [ "light", "--text", "--bg", 4.48 ] ],
      pending: false },
    { id: "adv2-imp-two-layers", cls: :block_nesting,
      files: { "tokens.css" => "@layer a, b;\n@layer a{:root{--text:#000000 !important}}\n@layer b{:root{--text:#777777 !important}}\n:root{--bg:#ffffff}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv2-anon-layer", cls: :block_nesting,
      files: { "tokens.css" => ":root{--text:#000000}\n@layer{:root{--text:#777777}}\n:root{--bg:#ffffff}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv2-dotted-layer", cls: :block_nesting,
      files: { "tokens.css" => ":root{--text:#000000}\n@layer a.b{:root{--text:#777777}}\n:root{--bg:#ffffff}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv2-nested-layer", cls: :block_nesting,
      files: { "tokens.css" => "@layer a{:root{--text:#000000} @layer b{:root{--text:#777777}}}\n:root{--bg:#ffffff}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv2-import-layer-order", cls: :block_nesting,
      files: { "tokens.css" => "@import url(other.css) layer(b);\n:root{--bg:#ffffff}\n@layer a{:root{--text:#777777}}\n@layer b{:root{--text:#000000}}\n" },
      contrast: [ [ "light", "--text", "--bg", 4.48 ] ],
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
    { id: "adv1-media-theme-before-base-source-order", cls: :theme_contexts,
      files: { "tokens.css" => "@media (prefers-color-scheme: dark){:root{--text:#fff}}\n:root{--bg:#000;--text:#000}\n" },
      contrast: [ [ "light", "--text", "--bg", 1.0 ], [ "dark", "--text", "--bg", 1.0 ] ],
      pending: false },
    { id: "adv1-media-theme-before-base-source-order-sibling-dark-before-root", cls: :theme_contexts,
      files: { "tokens.css" => ".dark{--bg:#000;--text:#fff}\n:root{--bg:#fff;--text:#000}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv1-important-ignored-in-cascade-a", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000 !important}\n:root{--text:#777}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv1-important-ignored-in-cascade-b", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000 !important}\n:root[data-theme=\"dark\"]{--bg:#000;--text:#fff}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 1.0 ] ],
      pending: false },
    { id: "adv1-specificity-ignored-root-vs-html", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000}\nhtml{--text:#777}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv1-specificity-ignored-root-vs-html-sibling-not-qualifier", cls: :theme_contexts,
      files: { "tokens.css" => ":root:not(.x){--text:#000} :root{--text:#777}\n:root{--bg:#fff}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "x", "--text", "--bg", 4.48 ] ],
      pending: false },
    { id: "adv1-not-qualifier-base-leaks-into-theme-a", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#fff}\n:root:not(.dark){--text:#000}\n.dark{--bg:#000}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv1-not-qualifier-base-leaks-into-theme-b", cls: :theme_contexts,
      files: { "tokens.css" => ":root:not([data-theme=\"dark\"]){--bg:#fff;--text:#000}\n:root[data-theme=\"dark\"]{--bg:#000}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv1-same-theme-split-across-selector-spellings-a", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000}\n:root[data-theme=\"dark\"]{--bg:#000}\n:root[data-theme=dark]{--text:#fff}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv1-same-theme-split-across-selector-spellings-b", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000}\n.dark{--bg:#000}\n:root.dark{--text:#fff}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv1-media-theme-not-combined-with-attr-variant", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000}\n@media (prefers-color-scheme: dark){:root{--bg:#000;--text:#fff}}\n:root[data-theme=\"light\"]{--bg:#fff}\n" },
      contrast: [ [ "light", "--text", "--bg", 1.0 ], [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv1-style-media-attribute-ignored", cls: :theme_contexts,
      files: { "index.html" => "<html><head>\n<style>:root{--bg:#fff;--text:#000}</style>\n<style media=\"(prefers-color-scheme: dark)\">:root{--bg:#000;--text:#777}</style>\n</head></html>\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 4.69 ] ],
      pending: false },
    { id: "adv1-root-selector-case-and-comment-a", cls: :theme_contexts,
      files: { "tokens.css" => ":ROOT{--bg:WHITE;--text:BlAcK}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv1-root-selector-case-and-comment-b", cls: :theme_contexts,
      files: { "tokens.css" => ":root{--bg:#fff;--text:#000}\n:root/* theme */[data-theme=\"dark\"]{--bg:#000;--text:#fff}\n" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ], [ "dark", "--text", "--bg", 21.0 ] ],
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
    { id: "adv1-scss-interpolation-drops-declarations", cls: :termination,
      files: { "tokens.scss" => ":root {\n  --bg: \#{$white};\n  --text: #000;\n  --text-muted: \#{$gray};\n}\n" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "unrecognized color value" ],
                  [ "light", "--text-muted", "--bg", :unresolved, "unrecognized color value" ] ],
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
    { id: "adv1-hsl-hue-units-a", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:#fff;--text:hsl(0.5turn 100% 25%)}" },
      contrast: [ [ "light", "--text", "--bg", 4.77 ] ],
      pending: false },
    { id: "adv1-hsl-hue-units-b", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:#fff;--text:hsl(3.14159rad 100% 25%)}" },
      contrast: [ [ "light", "--text", "--bg", 4.78 ] ],
      pending: false },
    { id: "hsl-hue-grad-unit", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:#fff;--text:hsl(200grad 100% 25%)}" },
      contrast: [ [ "light", "--text", "--bg", 4.77 ] ],
      pending: false },
    { id: "hsl-hue-invalid-unit-unresolved", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:#fff;--text:hsl(0.5foo 100% 25%)}" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "invalid hue" ] ],
      pending: false },
    { id: "adv1-invalid-color-syntax-resolved-a", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:#fff;--text:color-mix(in srgb, #000 150%, #fff)}" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "0% and 100%" ] ],
      pending: false },
    { id: "adv1-invalid-color-syntax-resolved-b", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:#fff;--text:rgb(100%, 0, 0)}" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "numbers or all percentages" ] ],
      pending: false },
    { id: "adv1-invalid-color-syntax-resolved-c", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:#fff;--text:rgb(0 0 0 0.2)}" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "unrecognized color value" ] ],
      pending: false },
    { id: "color-mix-negative-percentage-unresolved", cls: :color_syntax,
      files: { "tokens.css" => ":root{--bg:#fff;--text:color-mix(in srgb, #000 -10%, #fff)}" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "0% and 100%" ] ],
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
    { id: "adv1-var-in-color-function-channels-a", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#000;--r:255;--text:rgb(var(--r) var(--r) var(--r))}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "adv1-var-in-color-function-channels-b", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#fff;--h:240;--text:hsl(var(--h) 100% 30%)}" },
      contrast: [ [ "light", "--text", "--bg", 14.38 ] ],
      pending: false },
    { id: "var-channel-undefined-no-fallback-unresolved", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#000;--text:rgb(var(--missing) 0 0)}" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "is not defined in this theme" ] ],
      pending: false },
    { id: "var-channel-with-fallback-resolves", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#000;--text:rgb(var(--missing, 255) 255 255)}" },
      contrast: [ [ "light", "--text", "--bg", 21.0 ] ],
      pending: false },
    { id: "var-hue-channel-with-fallback-resolves", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#fff;--text:hsl(var(--missing-hue, 240) 100% 30%)}" },
      contrast: [ [ "light", "--text", "--bg", 14.38 ] ],
      pending: false },
    { id: "adv1-var-cycle-with-fallback-resolves-a", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#000;--a:var(--b, #000);--b:var(--a, #fff);--text:var(--a)}" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "cycle" ] ],
      pending: false },
    { id: "adv1-var-cycle-with-fallback-resolves-b", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#000;--text:var(--text, #fff)}" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "cycle" ] ],
      pending: false },
    { id: "var-cycle-with-fallback-in-channel-unresolved", cls: :value_functions,
      files: { "tokens.css" => ":root{--bg:#000;--r:var(--g, 1);--g:var(--r, 2);--text:rgb(var(--r) 0 0)}" },
      contrast: [ [ "light", "--text", "--bg", :unresolved, "cycle" ] ],
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
    { id: "adv1-text-role-middle-segment-zero-rows", cls: :pairing,
      files: { "tokens.css" => ":root{--color-bg:#fff;--color-text-muted:#777;--color-fg-default:#000;--brand-link-hover:#00f}" },
      contrast: [ [ "light", "--color-text-muted", "--color-bg", 4.48 ],
                  [ "light", "--color-fg-default", "--color-bg", 21.0 ],
                  [ "light", "--brand-link-hover", "--color-bg", 8.59 ] ],
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
    { id: "adv1-named-color-ident-in-non-color-property", cls: :false_positives,
      files: { "a.css" => "@keyframes snow { from { opacity: 0 } }\n.x { animation: snow 2s linear; grid-area: navy; }\n",
               "b.css" => "body { font-family: Red Hat Text, system-ui, sans-serif; }\n" },
      findings: [],
      pending: false },
    { id: "adv1-named-color-ident-sibling-color-bearing-still-flags", cls: :false_positives,
      files: { "extra.css" => ".a { container-name: red; }\n.b { color: red; }\n" },
      findings: [ [ "extra.css", 2, "literal" ] ],
      pending: false },
    { id: "adv1-markup-attr-regex-scans-text-nodes", cls: :false_positives,
      files: { "docs.html" => "<p>Write <code>&lt;path fill=\"red\"/&gt;</code> or style=\"color: #123456\" in prose.</p>\n" },
      findings: [],
      pending: false },
    { id: "adv1-vue-bound-attrs", cls: :false_positives,
      files: { "comp.vue" => "<template>\n  <svg><path :fill=\"red\" /></svg>\n  <div :style=\"{ color: accent }\"></div>\n  <div :style=\"{ color: '#abc' }\"></div>\n</template>\n" },
      findings: [ [ "comp.vue", 4, "literal" ] ],
      pending: false },
    { id: "adv1-vue-bound-attrs-sibling-v-bind-long-form", cls: :false_positives,
      files: { "comp2.vue" => "<template>\n  <div v-bind:style=\"{ color: accent }\"></div>\n  <div v-bind:style=\"{ color: '#def' }\"></div>\n</template>\n" },
      findings: [ [ "comp2.vue", 3, "literal" ] ],
      pending: false },
    { id: "adv1-data-attr-suffix-match", cls: :false_positives,
      files: { "page.html" => "<div data-fill=\"red\" data-style=\"color: blue\">x</div>\n" },
      findings: [],
      pending: false },
    { id: "adv1-data-attr-suffix-match-sibling-x-style-and-data-classname", cls: :false_positives,
      files: { "page2.html" => "<div x-style=\"color:red\" data-classname=\"foo\">x</div>\n" },
      findings: [],
      pending: false },
    { id: "adv1-html-comment-attr-flagged", cls: :false_positives,
      files: { "page.html" => "<!-- <div style=\"color:#123456\"></div> -->\n<p>ok</p>\n" },
      findings: [],
      pending: false },
    { id: "adv1-html-comment-attr-flagged-sibling-multiline-comment", cls: :false_positives,
      files: { "page4.html" => "<!-- first\nsecond style=\"color:red\"\nthird -->\n<div style=\"color:#123456\"></div>\n" },
      findings: [ [ "page4.html", 4, "literal" ] ],
      pending: false },
    { id: "adv1-jsx-text-quotes-flagged", cls: :false_positives,
      files: { "Pick.jsx" => "export const P = () => <p>Pick 'red' or 'blue' for the team</p>;\n" },
      findings: [],
      pending: false },
    { id: "adv1-jsx-text-quotes-flagged-sibling-apostrophe-and-tailwind", cls: :false_positives,
      files: { "Nested.jsx" => "export const N = () => <div>Won't <span className=\"bg-red-500\">stop</span></div>;\n" },
      findings: [ [ "Nested.jsx", 1, "tailwind" ] ],
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
    { id: "adv1-css-scan-misses-uppercase-and-other-color-fns", cls: :stray_scope,
      files: { "extra.css" => ".a { color: RGB(255, 0, 0); }\n.b { color: hwb(0 0% 0%); }\n.c { background: Linear-Gradient(red, blue); }\n.d { color: color(display-p3 1 0 0); }\n" },
      findings: [ [ "extra.css", 1, "literal" ], [ "extra.css", 2, "literal" ], [ "extra.css", 3, "gradient" ],
                  [ "extra.css", 3, "literal" ], [ "extra.css", 3, "literal" ], [ "extra.css", 4, "literal" ] ],
      pending: false },
    { id: "adv1-css-scan-misses-uppercase-sibling-oklch-and-radial", cls: :stray_scope,
      files: { "extra.css" => ".a { color: OkLCH(0.5 0.1 90); }\n.b { background: RADIAL-GRADIENT(red, blue); }\n" },
      findings: [ [ "extra.css", 1, "literal" ], [ "extra.css", 2, "gradient" ],
                  [ "extra.css", 2, "literal" ], [ "extra.css", 2, "literal" ] ],
      pending: false },
    { id: "adv1-hash-token-glued-to-ident", cls: :stray_scope,
      files: { "extra.css" => ".a { border: 1px solid#123456; }\n" },
      findings: [ [ "extra.css", 1, "literal" ] ],
      pending: false },
    { id: "adv1-hash-token-glued-to-ident-sibling-hyphenated-ident", cls: :stray_scope,
      files: { "extra.css" => ".a { background: no-repeat#123456; }\n" },
      findings: [ [ "extra.css", 1, "literal" ] ],
      pending: false },
    { id: "adv1-less-variable-declaration-not-scanned", cls: :stray_scope,
      files: { "extra.less" => "@c: #123456;\n.x { color: @c; border-color: Teal; }\n" },
      findings: [ [ "extra.less", 1, "literal" ], [ "extra.less", 2, "literal" ] ],
      pending: false },
    { id: "adv1-less-variable-declaration-sibling-named-color-value", cls: :stray_scope,
      files: { "extra.less" => "@brand: Teal;\n.y { color: @brand; }\n" },
      findings: [ [ "extra.less", 1, "literal" ] ],
      pending: false },
    { id: "adv1-markup-unquoted-attr", cls: :stray_scope,
      files: { "page.html" => "<div style=color:#123456>x</div>\n<svg><path fill=red /></svg>\n" },
      findings: [ [ "page.html", 1, "literal" ], [ "page.html", 2, "literal" ] ],
      pending: false },
    { id: "adv1-markup-unquoted-attr-sibling-multi-declaration", cls: :stray_scope,
      files: { "page3.html" => "<div style=color:red;background:blue>x</div>\n" },
      findings: [ [ "page3.html", 1, "literal" ], [ "page3.html", 1, "literal" ] ],
      pending: false },
    { id: "adv1-markup-multiline-attr-line", cls: :stray_scope,
      files: { "page.html" => "<div\n  style=\"\n    color: #123456;\n    background: red\n  \">x</div>\n" },
      findings: [ [ "page.html", 3, "literal" ], [ "page.html", 4, "literal" ] ],
      pending: false },
    { id: "adv1-jsx-apostrophe-swallows-string", cls: :stray_scope,
      files: { "A.jsx" => "export const A = () => <p>Don't <span style={{ color: '#f00' }}>x</span></p>;\n" },
      findings: [ [ "A.jsx", 1, "literal" ] ],
      pending: false },
    { id: "adv1-js-regex-literal-swallows-string", cls: :stray_scope,
      files: { "B.js" => "const re = /\"/g; const s = { color: '#abc' };\n" },
      findings: [ [ "B.js", 1, "literal" ] ],
      pending: false },
    { id: "adv1-js-regex-literal-sibling-division-not-regex", cls: :stray_scope,
      files: { "D.js" => "const r = a / b; const s = '#123456';\n" },
      findings: [ [ "D.js", 1, "literal" ] ],
      pending: false },
    { id: "adv1-js-regex-literal-sibling-escaped-slash-in-regex", cls: :stray_scope,
      files: { "E.js" => "const re = /a\\/b/; const s = '#abcdef';\n" },
      findings: [ [ "E.js", 1, "literal" ] ],
      pending: false },
    { id: "adv1-template-interpolation-strings-skipped", cls: :stray_scope,
      files: { "C.js" => "const c = `${dark ? '#000000' : '#ffffff'}`;\n" },
      findings: [ [ "C.js", 1, "literal" ], [ "C.js", 1, "literal" ] ],
      pending: false },
    { id: "adv2-markup-comment-in-script", cls: :stray_scope,
      files: { "a.html" => "<script>var a='<!--';</script>\n<p style=\"color:#abcdef\">-->x</p>" },
      findings: [ [ "a.html", 2, "literal" ] ],
      pending: false },
    { id: "adv2-markup-comment-in-attr", cls: :stray_scope,
      files: { "a.html" => "<div title=\"<!--\" style=\"color:#abcdef\"></div><p>--></p>",
               "b.html" => "<div title='<!--' style=\"color:#abcdef\"></div><p>--></p>" },
      findings: [ [ "a.html", 1, "literal" ], [ "b.html", 1, "literal" ] ],
      pending: false },
    { id: "adv2-style-tag-in-script-string", cls: :stray_scope,
      files: { "a.html" => "<script>var a='<style>';</script>\n<p style=\"color:#abcdef\"></p><style>p{}</style>" },
      findings: [ [ "a.html", 2, "literal" ] ],
      pending: false },
    { id: "adv2-rcdata-textarea", cls: :stray_scope,
      files: { "a.html" => "<textarea><b style=\"color:#abcdef\"></b></textarea>",
               "b.html" => "<title><i fill=\"#abcdef\"></i></title>" },
      findings: [],
      pending: false },
    { id: "adv2-cdata-in-svg", cls: :stray_scope,
      files: { "a.html" => "<svg><![CDATA[ <rect fill=\"#abcdef\"/> ]]></svg>",
               "b.html" => "<![CDATA[ <p style=\"color:#abcdef\"></p> ]]>" },
      findings: [],
      pending: false },
    { id: "adv2-js-regex-after-paren-keyword", cls: :stray_scope,
      files: { "a.js" => "if (x) /'/.test(s); const c = '#abcdef';\n",
               "w.js" => "while (ok) /\"/.exec(s); const c = '#abcdef';\n" },
      findings: [ [ "a.js", 1, "literal" ], [ "w.js", 1, "literal" ] ],
      pending: false },
    { id: "adv2-js-property-keyword", cls: :stray_scope,
      files: { "a.js" => "const x = a.return / 2; const c = '#abcdef'; const y = b / 3;\n",
               "b.js" => "const z = a?.return / 2; const d = '#fedcba';\n" },
      findings: [ [ "a.js", 1, "literal" ], [ "b.js", 1, "literal" ] ],
      pending: false },
    { id: "adv2-js-postfix-increment", cls: :stray_scope,
      files: { "a.js" => "x = y++ / 2; const c = '#abcdef'; z = w / 3;\n",
               "b.js" => "x = y-- / 2; const d = '#fedcba'; z = w / 3;\n" },
      findings: [ [ "a.js", 1, "literal" ], [ "b.js", 1, "literal" ] ],
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

  def test_corpus_has_no_pending_rows
    pending = CORPUS.select { |row| row[:pending] }
    assert_empty pending.map { |row| row[:id] }, "pending corpus rows remain"
  end

  # Builds the same theme model compute_contrast builds internally (from the
  # same detected token file), and checks that the contrast report matches
  # it one row per text-role key: every variant's effective map yields
  # exactly one row per text role for that theme and context, every
  # unsupported context yields exactly one row per text-role token it
  # declares, and every unresolved row carries a non-empty reason. A row
  # whose files raise during ColorCheck.run fails this test with that error.
  def test_corpus_invariant_one_row_per_text_role
    CORPUS.each do |row|
      with_dir do |dir|
        row[:files].each { |rel, content| write(dir, rel, content) }
        report = ColorCheck.run(dir)

        token_file = ColorCheck.detect_token_file(ColorCheck.scan_files(dir))
        if token_file
          sheet = ColorCheck.parse_token_sheet(token_file)
          model = sheet ? ColorThemes.build(sheet) : nil

          model&.variants&.each do |variant|
            context = variant.contexts.join(" | ")
            variant.decls.each_key.select { |name| ColorThemes.text_role_name?(name) }.each do |role|
              matches = report.contrast.select do |c|
                c.theme == variant.theme && c.context == context && c.text_token == role
              end
              assert_equal 1, matches.size,
                           "#{row[:id]}: expected one row for theme=#{variant.theme} " \
                           "context=#{context} role=#{role}, got #{matches.size}"
            end
          end

          model&.unsupported&.each do |uns|
            uns.decls.each_key.select { |name| ColorThemes.text_role_name?(name) }.each do |role|
              matches = report.contrast.select do |c|
                c.theme == "unsupported" && c.context == uns.label && c.text_token == role
              end
              assert_equal 1, matches.size,
                           "#{row[:id]}: expected one unsupported row for label=#{uns.label} " \
                           "role=#{role}, got #{matches.size}"
            end
          end
        end

        report.contrast.each do |pair|
          next if pair.resolved

          refute_nil pair.reason, "#{row[:id]}: unresolved row for #{pair.text_token} has no reason"
          refute_empty pair.reason.to_s, "#{row[:id]}: unresolved row for #{pair.text_token} has an empty reason"
        end
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

  def test_tokens_flag_relative_path_is_exempt_despite_different_spelling
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      Dir.chdir(dir) do
        # root "." makes Find yield "./tokens.css" while tokens_override is
        # given as the bare relative "tokens.css": different spellings of the
        # same file, which must still be recognized as the token file.
        report = ColorCheck.run(".", tokens_override: "tokens.css")
        assert_empty report.findings
      end
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

  def test_foreground_pairs_with_background_and_resolves
    with_dir do |dir|
      write(dir, "tokens.css", ":root {\n  --background: #ffffff;\n  --foreground: #000000;\n}\n")
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.text_token == "--foreground" }
      refute_nil pair
      assert pair.resolved
      assert_equal "--background", pair.bg_token
      assert_in_delta 21.0, pair.ratio, 0.01
    end
  end

  def test_sheet_without_text_roles_reports_one_unresolved_row
    with_dir do |dir|
      write(dir, "tokens.css", ":root {\n  --brand: #123456;\n  --surface: #ffffff;\n}\n")
      report = ColorCheck.run(dir, strict: true)
      assert_equal 1, report.contrast.size
      row = report.contrast.first
      refute row.resolved
      assert_nil row.text_token
      assert_includes row.reason, "no text-role tokens recognized"
      text = ColorCheck.render(report)
      assert_includes text, "[unresolved] no text-role tokens recognized in"
      refute_includes text, " on :"
      json = JSON.parse(ColorCheck.to_json_report(report))
      assert_equal 1, json["contrast"].size
      assert_includes json["contrast"].first["reason"], "no text-role tokens recognized"
      assert_equal 0, report.exit_code
    end
  end

  def test_unknown_context_short_hex_is_unresolved_and_not_strict
    with_dir do |dir|
      write(dir, "a.js", "const c = dark ? '#fff' : base;\n")
      report = ColorCheck.run(dir, strict: true)
      assert_equal [], report.findings
      assert_equal 1, report.unresolved.size
      assert_equal 0, report.exit_code
      text = ColorCheck.render(report)
      assert_includes text, "Unresolved (not counted by --strict):"
      assert_includes text, "#fff (key context could not be determined)"
      json = JSON.parse(ColorCheck.to_json_report(report))
      assert_equal "#fff", json["unresolved"].first["text"]
    end
  end

  def test_jsx_fill_expression_is_a_strict_finding
    with_dir do |dir|
      write(dir, "a.jsx", "export const I = () => <path fill={'#f00'} />;\n")
      report = ColorCheck.run(dir, strict: true)
      assert_equal 1, report.findings.size
      assert_equal 1, report.exit_code
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
