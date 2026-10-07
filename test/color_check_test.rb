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
    :root {
      --cream: #f6efe0;
      --plum: #24122a;
      --lilac: #a070c8;
      --pink: #f2c4c4;
      --background: var(--cream);
      --page-text: var(--plum);
    }

    :root[data-theme="dark"] {
      --background: var(--plum);
      --page-text: var(--cream);
    }
  CSS

  # Each row states what the token-file grammar and the stray scan define,
  # not what the checker does today; pending: true marks a row the current
  # code still fails. Expected ratios come from an independent WCAG
  # calculation, never from the checker. token_errors lists one message
  # fragment per expected token-file error; a row with palette or contrast
  # and no token_errors expects none.
  CORPUS = [
    # :comments
    { id: "comments-block-comment-not-mid-value", cls: :comments,
      files: { "tokens.css" => ":root{--background:#fff;/* --page-text: #fff; */--page-text:#000;}" },
      palette: [ "#fff", "#000" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "comments-block-comment-with-brace", cls: :comments,
      files: { "tokens.css" => ":root{--background:#fff; /* } */ --page-text:#777;}" },
      contrast: [ [ "light", "--page-text", "--background", 4.48 ] ],
      pending: false },
    # :strings
    { id: "strings-semicolon-and-brace-in-value-string", cls: :strings,
      files: { "tokens.css" => ":root {\n  --background: #fff;\n  --label: \"a;b}c\";\n  --page-text: #000;\n}\n" },
      palette: [ "#fff", "#000" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    # :token_grammar, one row per construct the token-file grammar rejects
    # or accepts, checked through the whole run
    { id: "grammar-media-min-width-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => "@media (min-width: 40em) { :root { --page-text: #777 } }" },
      token_errors: [ "@media (min-width: 40em)" ],
      contrast: [],
      pending: false },
    { id: "grammar-layer-base-wrapper-accepted", cls: :token_grammar,
      files: { "tokens.css" => "@layer base { :root { --background:#fff; --page-text:#000 } }" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "grammar-nested-layer-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => "@layer a{:root{--page-text:#000000} @layer b{:root{--page-text:#777777}}}\n:root{--background:#ffffff}\n" },
      token_errors: [ "@layer b" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "grammar-redeclared-light-value-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000}\n@layer base{:root{--page-text:#777}}\n" },
      token_errors: [ "--page-text` is declared twice in light" ],
      pending: false },
    { id: "grammar-supports-and-container-are-errors", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000}\n@supports (color: red){:root{--page-text:#777}}\n@container (min-width: 1px){:root{--page-text:#111}}\n" },
      token_errors: [ "@supports", "@container" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "grammar-descendant-and-print-media-are-errors", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000}\n.card p{--page-text:#777}\n@media print{.card p{--link-text:#00f}}\n" },
      token_errors: [ ".card p", "@media print" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "grammar-root-descendant-dark-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000}\n:root .dark{--page-text:#fff}\n" },
      token_errors: [ "selector `:root .dark` is not a token block" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "grammar-html-selector-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => "html{--background:#fff;--page-text:#000} html.dark{--background:#000;--page-text:#fff}" },
      token_errors: [ "`html`", "`html.dark`" ],
      contrast: [],
      pending: false },
    { id: "grammar-light-data-theme-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => ':root{--background:#000} :root[data-theme="light"]{--background:#fff;--page-text:#000}' },
      token_errors: [ ':root[data-theme="light"]' ],
      contrast: [],
      pending: false },
    { id: "grammar-other-theme-name-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => ':root{--background:#fff;--page-text:#000} :root[data-theme="dim"]{--background:#333}' },
      token_errors: [ '[data-theme="dim"]' ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "grammar-normal-property-in-dark-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#000;--page-text:#000} .dark{--page-text:#fff; color-scheme: dark}" },
      token_errors: [ "color-scheme" ],
      contrast: [ [ "light", "--page-text", "--background", 1.0 ], [ "dark", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "grammar-not-qualifier-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff}\n:root:not(.dark){--page-text:#000}\n" },
      token_errors: [ ":root:not(.dark)" ],
      contrast: [],
      pending: false },
    { id: "grammar-media-dark-only-takes-root", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000}\n@media (prefers-color-scheme: dark) { .dark { --background: #000; } }\n" },
      token_errors: [ "inside prefers-color-scheme media" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "grammar-new-name-in-dark-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff}\n.dark{--page-text:#fff}\n" },
      token_errors: [ "--page-text` is declared in dark but not in light" ],
      contrast: [],
      pending: false },
    { id: "grammar-two-dark-blocks-disagree-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000}\n.dark{--page-text:#fff}\n[data-theme=dark]{--page-text:#eee}\n" },
      token_errors: [ "declared twice in dark" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "dark", "--page-text", "--background", 1.0 ] ],
      pending: false },

    # :variants, light and dark from every accepted spelling
    { id: "variants-media-dark-override", cls: :variants,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000;--a:#123;} @media (prefers-color-scheme: dark){:root{--background:#000;--page-text:#777;}}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "dark", "--page-text", "--background", 4.69 ] ],
      pending: false },
    { id: "variants-identical-light-and-dark-both-checked", cls: :variants,
      files: { "tokens.css" => ':root{--background:#fff;--page-text:#777;} :root[data-theme="dark"]{--background:#fff;--page-text:#777;}' },
      contrast: [ [ "light", "--page-text", "--background", 4.48 ], [ "dark", "--page-text", "--background", 4.48 ] ],
      pending: false },
    { id: "variants-shadcn-bare-dark-class", cls: :variants,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000} .dark{--background:#000;--page-text:#fff}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "dark", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "variants-bare-data-theme-attr-inherits-light", cls: :variants,
      files: { "tokens.css" => ':root{--background:#000;--page-text:#000} [data-theme="dark"]{--page-text:#fff}' },
      contrast: [ [ "light", "--page-text", "--background", 1.0 ], [ "dark", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "variants-root-dark-class", cls: :variants,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000} :root.dark{--background:#000;--page-text:#fff}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "dark", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "variants-split-root-rules-combine", cls: :variants,
      files: { "tokens.css" => ":root { --cream: #ffffff; --plum: #000000; } :root { --background: var(--cream); } :root { --page-text: var(--plum); }" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "variants-four-color-tokens-fixture", cls: :variants,
      files: { "tokens.css" => FOUR_COLOR_TOKENS },
      palette: [ "#f6efe0", "#24122a", "#a070c8", "#f2c4c4" ],
      pending: false },
    { id: "variants-media-dark-before-root", cls: :variants,
      files: { "tokens.css" => "@media (prefers-color-scheme: dark){:root{--page-text:#fff}}\n:root{--background:#000;--page-text:#000}\n" },
      contrast: [ [ "light", "--page-text", "--background", 1.0 ], [ "dark", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "variants-dark-class-before-root", cls: :variants,
      files: { "tokens.css" => ".dark{--background:#000;--page-text:#fff}\n:root{--background:#fff;--page-text:#000}\n" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "dark", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "variants-dark-split-across-spellings", cls: :variants,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000}\n:root[data-theme=\"dark\"]{--background:#000}\n:root[data-theme=dark]{--page-text:#fff}\n.dark{--page-text:#fff}\n" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "dark", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "variants-root-selector-case", cls: :variants,
      files: { "tokens.css" => ":ROOT{--background:WHITE;--page-text:BlAcK}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "variants-comment-inside-compound-selector", cls: :variants,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000}\n:root/* theme */[data-theme=\"dark\"]{--background:#000;--page-text:#fff}\n" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "dark", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "variants-ordinary-rule-in-token-file", cls: :variants,
      files: { "tokens.css" => ":root{--background:#fff} .card{color:red; --page-text:#000}" },
      token_errors: [ ".card" ],
      findings: [ [ "tokens.css", 1, "literal" ] ],
      contrast: [],
      pending: false },
    # :termination
    { id: "termination-repro5-no-mid-semicolons", cls: :termination,
      files: { "tokens.css" => ":root{--a:#123;--background:#fff;--page-text:#000}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "termination-last-declaration-keeps-authored", cls: :termination,
      files: { "tokens.css" => ":root { --background: #fff; --last: #555 }\n.hero { color: #abcdef; }\n" },
      palette: [ "#fff", "#555" ],
      findings: [ [ "tokens.css", 2, "literal" ] ],
      token_errors: [ ".hero" ],
      pending: false },
    { id: "termination-multiline-exempt-correct-lines", cls: :termination,
      files: { "tokens.css" => ":root {\n  --cream: #f6efe0;\n  --plum: #24122a;\n}\n:root {\n  --brand:\n    #123456;\n}\n.x { color: #abcdef; }\n" },
      palette: [ "#f6efe0", "#24122a", "#123456" ],
      findings: [ [ "tokens.css", 9, "literal" ] ],
      token_errors: [ ".x" ],
      pending: false },
    # :color_syntax
    { id: "color-syntax-named-white-black", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:white;--page-text:black}" },
      palette: [ "white", "black" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "color-syntax-rgb-space-and-comma", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:rgb(255 255 255);--page-text:rgb(0,0,0)}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "color-syntax-hsl-space-percent", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:hsl(0 0% 100%);--page-text:#000000}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "color-syntax-important-resolves", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff !important;--page-text:#000}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "color-syntax-oklch-unresolved-reason", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:oklch(0.5 0.1 90)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "oklch" ] ],
      pending: false },
    { id: "adv1-hsl-hue-units-a", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:hsl(0.5turn 100% 25%)}" },
      contrast: [ [ "light", "--page-text", "--background", 4.77 ] ],
      pending: false },
    { id: "adv1-hsl-hue-units-b", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:hsl(3.14159rad 100% 25%)}" },
      contrast: [ [ "light", "--page-text", "--background", 4.78 ] ],
      pending: false },
    { id: "hsl-hue-grad-unit", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:hsl(200grad 100% 25%)}" },
      contrast: [ [ "light", "--page-text", "--background", 4.77 ] ],
      pending: false },
    { id: "hsl-hue-invalid-unit-unresolved", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:hsl(0.5foo 100% 25%)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "invalid hue" ] ],
      pending: false },
    { id: "adv1-invalid-color-syntax-resolved-a", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:color-mix(in srgb, #000 150%, #fff)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "0% and 100%" ] ],
      pending: false },
    { id: "adv1-invalid-color-syntax-resolved-b", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:rgb(100%, 0, 0)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "numbers or all percentages" ] ],
      pending: false },
    { id: "adv1-invalid-color-syntax-resolved-c", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:rgb(0 0 0 0.2)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "unrecognized color value" ] ],
      pending: false },
    { id: "color-mix-negative-percentage-unresolved", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:color-mix(in srgb, #000 -10%, #fff)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "0% and 100%" ] ],
      pending: false },
    # :value_functions
    { id: "round4-color-mix-var-arguments", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000;--muted-text:color-mix(in srgb, var(--page-text) 60%, var(--background))}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "light", "--muted-text", "--background", 5.74 ] ],
      pending: false },
    { id: "repro16-color-mix-var-second-stop", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000;--muted-text:color-mix(in srgb, var(--page-text), var(--background) 40%)}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "light", "--muted-text", "--background", 5.74 ] ],
      pending: false },
    { id: "repro15-var-fallback-missing-token", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#fff;--page-text: var(--missing, #000)}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "value-functions-var-cycle-no-raise", cls: :value_functions,
      files: { "tokens.css" => ":root { --background: #fff; --page-text: var(--page-text); --a: var(--b); --b: var(--a); }" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "cycle" ] ],
      pending: false },
    { id: "value-functions-color-mix-oklch-unresolved", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:color-mix(in oklch, white 50%, black 50%)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "oklch" ] ],
      pending: false },
    { id: "value-functions-color-mix-transparent-matches-today", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#fff;--x:#000000;--page-text:color-mix(in srgb, var(--x) 12%, transparent)}" },
      contrast: [ [ "light", "--page-text", "--background", 1.32 ] ],
      pending: false },
    { id: "adv1-var-in-color-function-channels-a", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#000;--r:255;--page-text:rgb(var(--r) var(--r) var(--r))}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "adv1-var-in-color-function-channels-b", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#fff;--h:240;--page-text:hsl(var(--h) 100% 30%)}" },
      contrast: [ [ "light", "--page-text", "--background", 14.38 ] ],
      pending: false },
    { id: "var-channel-undefined-no-fallback-unresolved", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#000;--page-text:rgb(var(--missing) 0 0)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "is not defined in this theme" ] ],
      pending: false },
    { id: "var-channel-with-fallback-resolves", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#000;--page-text:rgb(var(--missing, 255) 255 255)}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "var-hue-channel-with-fallback-resolves", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:hsl(var(--missing-hue, 240) 100% 30%)}" },
      contrast: [ [ "light", "--page-text", "--background", 14.38 ] ],
      pending: false },
    { id: "adv1-var-cycle-with-fallback-resolves-a", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#000;--a:var(--b, #000);--b:var(--a, #fff);--page-text:var(--a)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "cycle" ] ],
      pending: false },
    { id: "adv1-var-cycle-with-fallback-resolves-b", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#000;--page-text:var(--page-text, #fff)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "cycle" ] ],
      pending: false },
    { id: "var-cycle-with-fallback-in-channel-unresolved", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#000;--r:var(--g, 1);--g:var(--r, 2);--page-text:rgb(var(--r) 0 0)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "cycle" ] ],
      pending: false },
    # :pairing, the fixed rule: "--x-<suffix>" pairs with "--x" when
    # declared, else with "--background"; no other name pairs
    { id: "pairing-base-text-pairs-with-base", cls: :pairing,
      files: { "tokens.css" => ":root{--gold-btn:#000000;--gold-btn-text:#ffffff;--background:#000000}" },
      contrast: [ [ "light", "--gold-btn-text", "--gold-btn", 21.0 ] ],
      pending: false },
    { id: "pairing-every-suffix-without-surface-pairs-with-background", cls: :pairing,
      files: { "tokens.css" => ":root{--background:#fff;--a-text:#000;--b-fg:#000;--c-foreground:#777;--d-ink:#000}" },
      contrast: [ [ "light", "--a-text", "--background", 21.0 ], [ "light", "--b-fg", "--background", 21.0 ],
                  [ "light", "--c-foreground", "--background", 4.48 ], [ "light", "--d-ink", "--background", 21.0 ] ],
      pending: false },
    { id: "pairing-names-without-a-suffix-do-not-pair", cls: :pairing,
      files: { "tokens.css" => ":root {\n  --background: #ffffff;\n  --context: #112233;\n  --ink-like: #445566;\n  --ink: #000000;\n}\n" },
      contrast: [],
      pending: false },
    { id: "pairing-middle-segment-roles-do-not-pair", cls: :pairing,
      files: { "tokens.css" => ":root{--background:#fff;--color-text-muted:#777;--color-fg-default:#000;--brand-link-hover:#00f}" },
      contrast: [],
      pending: false },
    { id: "pairing-missing-background-is-unresolved", cls: :pairing,
      files: { "tokens.css" => ":root{--page-text:#000}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "--background: is not declared" ] ],
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
      findings: [ [ "extra.js", 1, "literal" ] ],
      pending: false },
    { id: "fp-link-with-hex-fragment", cls: :false_positives,
      files: { "extra.js" => "const link = '/page#feed';\n" },
      findings: [],
      pending: false },
    { id: "fp-bare-three-digit-hex-in-string", cls: :false_positives,
      files: { "extra.js" => "const a = '#add';\n" },
      findings: [ [ "extra.js", 1, "literal" ] ],
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
    { id: "fp-scss-function-names-sharing-color-fn-suffix", cls: :false_positives,
      files: { "extra.scss" => ".a { width: theme-rgb(1); }\n.b { height: my-hsl(foo); }\n.c { margin: not-linear-gradient(1); }\n" },
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
      findings: [],
      pending: false },
    # :stray_scope
    { id: "stray-button-jsx-oklch-not-scanned", cls: :stray_scope,
      files: { "src/Button.jsx" => "const a = \"#ff0000\";\nconst b = \"rgb(1,2,3)\";\nconst c = \"hsl(0, 0%, 0%)\";\nconst d = \"oklch(0.5 0.1 90)\";\n" },
      findings: [ [ "src/Button.jsx", 1, "literal" ], [ "src/Button.jsx", 2, "literal" ], [ "src/Button.jsx", 3, "literal" ] ],
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
      findings: [ [ "extra.html", 1, "literal" ], [ "extra.html", 1, "literal" ] ],
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
      findings: [ [ "extra.css", 1, "tailwind" ] ],
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
      findings: [],
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
      tokens: [],
      pending: false },
    { id: "adv2-rcdata-textarea", cls: :stray_scope,
      files: { "a.html" => "<textarea><b style=\"color:#abcdef\"></b></textarea>",
               "b.html" => "<title><i fill=\"#abcdef\"></i></title>" },
      findings: [],
      tokens: [],
      pending: false },
    { id: "adv2-cdata-in-svg", cls: :stray_scope,
      files: { "a.html" => "<svg><![CDATA[ <rect fill=\"#abcdef\"/> ]]></svg>",
               "b.html" => "<![CDATA[ <p style=\"color:#abcdef\"></p> ]]>" },
      findings: [],
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
      files: { "tokens.css" => ":root {\n  --cream: #ffffff;\n  --plum: #000000;\n  --background: var(--cream);\n  --page-text: var(--plum);\n}\n\n:root[data-theme=\"dark\"] {\n  --background: var(--plum);\n  --page-text: var(--cream);\n}\n" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "dark", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "past-a55862c-composite-eight-digit-alpha-hex", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --background: #ffffff;\n  --page-text: #00000000;\n}\n" },
      contrast: [ [ "light", "--page-text", "--background", 1.0 ] ],
      pending: false },
    { id: "past-9345400-anchor-text-name-to-segments", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --background: #ffffff;\n  --pink: #f2c4c4;\n  --ink: #000000;\n}\n" },
      contrast: [],
      pending: false },
    { id: "past-e24f742-scan-ordinary-rules-in-token-file", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --background: #ffffff;\n  --page-text: #000000;\n}\n.hero { background: linear-gradient(#fff, #000); color: #123456; }\n" },
      findings: [ [ "tokens.css", 5, "gradient" ], [ "tokens.css", 5, "literal" ], [ "tokens.css", 5, "literal" ], [ "tokens.css", 5, "literal" ] ],
      token_errors: [ ".hero" ],
      pending: false },
    { id: "past-016f07d-recognize-four-digit-hex", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --background: #ffff;\n  --page-text: #000f;\n}\n" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "past-b80c932-exempt-multiline-token-declarations", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --cream: #f6efe0;\n  --plum: #24122a;\n}\n:root {\n  --brand:\n    #123456;\n}\n.x { color: #abcdef; }\n" },
      findings: [ [ "tokens.css", 9, "literal" ] ],
      token_errors: [ ".x" ],
      pending: false },
    { id: "past-a58def4-stop-variable-cycles", cls: :past_findings,
      files: { "tokens.css" => ":root { --background: #fff; --page-text: var(--page-text); --a: var(--b); --b: var(--a); }\n" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved ] ],
      pending: false },
    { id: "past-1f3cac0-declaration-boundaries-without-semicolon", cls: :past_findings,
      files: { "tokens.css" => ":root { --background: #fff; --last: #555 }\n.hero { color: #abcdef; }\n" },
      palette: [ "#fff", "#555" ],
      findings: [ [ "tokens.css", 2, "literal" ] ],
      token_errors: [ ".hero" ],
      pending: false },
    { id: "past-e068235-accumulate-repeated-root-rules", cls: :past_findings,
      files: { "tokens.css" => ":root { --cream: #ffffff; --plum: #000000; }\n:root { --background: var(--cream); }\n:root { --page-text: var(--plum); }\n" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "past-567bce1-html-entity-hex-not-literal", cls: :past_findings,
      files: { "extra.tsx" => "const Arrow = () => <span>&#8599;</span>;\nconst style = { color: \"#abc\" };\n" },
      findings: [ [ "extra.tsx", 2, "literal" ] ],
      pending: false },
    { id: "past-567bce1-base-text-pairs-with-matching-base-token", cls: :past_findings,
      files: { "tokens.css" => ":root {\n  --btn: #000000;\n  --btn-text: #ffffff;\n  --background: #000000;\n}\n" },
      contrast: [ [ "light", "--btn-text", "--btn", 21.0 ] ],
      pending: false }
  ].freeze

  def relative_path(path, dir)
    Pathname.new(path).relative_path_from(Pathname.new(dir)).to_s
  end

  def contrast_match?(pair, expected_row)
    variant, fg, bg, *rest = expected_row
    return false unless pair.variant == variant && pair.fg == fg && pair.bg == bg

    if rest.first == :unresolved
      !pair.resolved? && (rest[1].nil? || pair.reason.to_s.include?(rest[1]))
    else
      pair.resolved? && (rest.first.nil? || (pair.ratio - rest.first).abs < 0.01)
    end
  end

  def describe_pairs(pairs)
    pairs.map { |p| [ p.variant, p.fg, p.bg, p.ratio, p.status ] }.inspect
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

  # The token side of a row: the declarations each file contributes as a
  # parsed CSS source, so a fake style element yields no declarations.
  def assert_corpus_tokens(row)
    row[:files].each do |rel, content|
      sheet = ColorCheck.css_source_sheet(rel, content)
      actual = sheet ? sheet.decls.map(&:name) : []
      assert_equal row[:tokens], actual, "tokens mismatch for #{row[:id]} #{rel}"
    end
  end

  def assert_token_errors(row, report)
    expected = row[:token_errors]
    expected ||= [] if row[:palette] || row[:contrast]
    return unless expected

    messages = report.token_errors.map(&:message)
    assert_equal expected.size, messages.size, "token errors for #{row[:id]}: #{messages.inspect}"
    expected.each do |fragment|
      assert(messages.any? { |m| m.include?(fragment) }, "#{row[:id]}: no token error mentions #{fragment}: #{messages.inspect}")
    end
  end

  def assert_corpus_row(row, report, dir)
    if row[:palette]
      actual = report.palette ? report.palette.authored.map { |a| a[:value] }.sort : []
      assert_equal row[:palette].sort, actual, "palette mismatch for #{row[:id]}"
    end

    assert_token_errors(row, report)
    assert_contrast_rows(row, report.contrast) if row[:contrast]
    assert_corpus_tokens(row) if row.key?(:tokens)
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

  # For every corpus row, the contrast report holds exactly one row per
  # declared pair (ColorTokens.pairs) per checked variant, light always and
  # dark only when the token file declares a dark block, nothing else, and
  # every unresolved row carries a reason. A row whose files raise during
  # ColorCheck.run fails this test with that error.
  def test_corpus_invariant_one_row_per_pair_per_variant
    CORPUS.each do |row|
      with_dir do |dir|
        row[:files].each { |rel, content| write(dir, rel, content) }
        report = ColorCheck.run(dir)
        expected = []
        if report.tokens
          tokens = ColorTokens.read(report.tokens)
          variants = tokens.dark? ? %i[light dark] : %i[light]
          variants.each do |v|
            ColorTokens.pairs(tokens.variants[v]).each { |fg, bg| expected << [ v.to_s, fg, bg ] }
          end
        end
        assert_equal expected.sort, report.contrast.map { |c| [ c.variant, c.fg, c.bg ] }.sort, row[:id]

        report.contrast.reject(&:resolved?).each do |pair|
          refute_empty pair.reason.to_s, "#{row[:id]}: unresolved row for #{pair.fg} has no reason"
        end
      end
    end
  end

  def test_four_authored_colors_reassigned_across_themes_count_as_four
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir)
      assert_equal 4, report.palette.authored.size
      assert_empty report.token_errors
    end
  end

  def test_error_token_excluded_and_fifth_color_is_a_token_error
    with_dir do |dir|
      css = FOUR_COLOR_TOKENS.sub("--pink: #f2c4c4;", "--pink: #f2c4c4;\n  --error: #ff0000;\n  --extra: #123456;")
      write(dir, "tokens.css", css)
      report = ColorCheck.run(dir, strict: true)
      assert report.palette.error_token
      assert_equal 5, report.palette.authored.size
      refute report.palette.authored.any? { |a| a[:names].include?("--error") }
      assert(report.token_errors.any? { |e| e.message.include?("palette has 5 authored colors") })
      assert_equal 1, report.exit_code
    end
  end

  def test_second_distinct_error_color_counts_toward_palette
    with_dir do |dir|
      css = FOUR_COLOR_TOKENS.sub("--pink: #f2c4c4;", "--pink: #f2c4c4;\n  --error: red;") \
                             .sub(':root[data-theme="dark"] {', ':root[data-theme="dark"] {' \
                                  "\n      --error: orange;")
      write(dir, "tokens.css", css)
      report = ColorCheck.run(dir, strict: true)
      assert report.palette.error_token
      assert_equal 5, report.palette.authored.size
      assert(report.token_errors.any? { |e| e.message.include?("palette has 5 authored colors") })
      assert_equal 1, report.exit_code
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
      assert_equal 3, literal_findings.size
      assert literal_findings.all? { |f| f.file.end_with?("Button.jsx") }
      assert_equal [ 1, 2, 3 ], literal_findings.map(&:line).sort
    end
  end

  def test_tailwind_classes_reported_and_semantic_class_not_reported
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "src/card.html", <<~HTML)
        <div class="bg-slate-100 text-blue-600 bg-primary">hi</div>
      HTML
      report = ColorCheck.run(dir)
      tailwind_findings = report.findings.select { |f| f.kind == "tailwind" }
      matches = tailwind_findings.map(&:text)
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

  def test_repeating_conic_gradient_reported
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "src/hero.css", ".hero { background: repeating-conic-gradient(red, blue 10%); }")
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

  def test_tokens_flag_overrides_the_path_list
    with_dir do |dir|
      write(dir, "tokens.css", ":root { --a: #111111; --b: #222222; --c: #333333; --d: #444444; --e: #555555; }")
      override_path = write(dir, "real-tokens.css", FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir, tokens_override: override_path)
      assert_equal override_path, report.palette.file
      assert_equal 4, report.palette.authored.size
      assert_empty report.token_errors
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
        assert_empty report.token_errors
      end
    end
  end

  def test_several_conventional_token_files_is_a_token_error
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "src/index.css", FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir, strict: true)
      assert_nil report.palette
      assert_includes report.token_errors.first.message, "several token files found"
      assert_equal 1, report.exit_code
      assert_includes ColorCheck.render(report), "error: several token files found"
    end
  end

  def test_default_exit_is_zero_even_with_findings_and_token_errors
    with_dir do |dir|
      write(dir, "tokens.css", "html{--a:#000}")
      write(dir, "src/Button.jsx", 'const a = "#ff0000";')
      report = ColorCheck.run(dir, strict: false)
      refute_empty report.token_errors
      assert_equal 0, report.exit_code
    end
  end

  def test_second_style_block_after_a_comment_reports_its_own_line
    html = "<style>:root{--a:#fff}</style>\n<!-- <style>\n:root{--b:#000}\n</style> -->\n" \
           "<p>x</p>\n<style>\n:root{\n--c:#111}</style>\n"
    sheet = ColorCheck.style_block_sheet(html)
    assert_equal [ [ "--a", 1 ], [ "--c", 8 ] ], sheet.decls.map { |d| [ d.name, d.line ] }
  end

  # style_block_sheet parses every <style> block through one parser, so
  # block ids never collide across blocks and an unclosed block in one
  # chunk never leaks into the next.
  def test_style_blocks_share_one_parse
    blocks = [
      "<style>.dark{--a:#000}</style>",
      "<style>.x{color:red}</style>",
      "<style></style>",
      "<style lang=\"scss\">.p{.q{--c:#222}}</style>",
      "<style>.open{--u:#333</style>",
      "<style>.after{--v:#444}</style>"
    ]
    sheet = ColorCheck.style_block_sheet(blocks.join("\n"))
    assert_equal sheet.blocks.size, sheet.blocks.map(&:id).uniq.size
    assert_equal 5, sheet.decls.map(&:block_id).uniq.size
    assert_nil sheet.blocks.find { |b| b.prelude == ".after" }.parent
    assert_equal [ ".after" ], sheet.decls.find { |d| d.name == "--v" }.selectors
    assert_equal 1, sheet.errors.size
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

  def test_strict_exits_one_with_findings_or_token_errors_and_zero_without
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "src/Button.jsx", 'const a = "#ff0000";')
      assert_equal 1, ColorCheck.run(dir, strict: true).exit_code
    end

    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS + ":root .dark { --page-text: #fff; }\n")
      report = ColorCheck.run(dir, strict: true)
      assert_empty report.findings
      assert_equal 1, report.exit_code
    end

    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      assert_equal 0, ColorCheck.run(dir, strict: true).exit_code
    end
  end

  def contrast_for(css, fg = "--page-text", variant: "light")
    with_dir do |dir|
      write(dir, "tokens.css", css)
      ColorCheck.run(dir).contrast.find { |c| c.fg == fg && c.variant == variant }
    end
  end

  def test_contrast_black_on_white_is_21
    pair = contrast_for(":root {\n  --background: #ffffff;\n  --page-text: #000000;\n}\n")
    assert pair.resolved?
    assert_in_delta 21.0, pair.ratio, 0.01
    assert_equal "pass", pair.status
  end

  def test_contrast_composites_eight_digit_alpha_hex
    pair = contrast_for(":root {\n  --background: #ffffff;\n  --page-text: #00000000;\n}\n")
    assert_in_delta 1.0, pair.ratio, 0.01
    assert_equal "fail", pair.status
  end

  def test_contrast_composites_four_digit_alpha_hex
    pair = contrast_for(":root {\n  --background: #ffff;\n  --page-text: #000f;\n}\n")
    assert_in_delta 21.0, pair.ratio, 0.01
  end

  def test_contrast_color_mix_pair_resolves
    pair = contrast_for(":root {\n  --background: #ffffff;\n  --plum: #24122a;\n" \
                        "  --page-text: color-mix(in srgb, var(--plum) 100%, transparent);\n}\n")
    assert pair.resolved?
  end

  def test_dark_override_resolves_against_light_palette_tokens
    pair = contrast_for(FOUR_COLOR_TOKENS, variant: "dark")
    assert pair.resolved?
    assert_equal "--background", pair.bg
  end

  def test_contrast_unresolvable_pair_listed_as_unresolved
    pair = contrast_for(":root {\n  --background: #ffffff;\n  --page-text: oklch(0.5 0.1 90);\n}\n")
    refute pair.resolved?
    assert_equal "unresolved", pair.status
    assert_includes pair.reason, "oklch"
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

  def test_contrast_suffix_token_paired_with_its_surface
    pair = contrast_for(":root {\n  --btn: #000000;\n  --btn-text: #ffffff;\n  --background: #000000;\n}\n", "--btn-text")
    assert_equal "--btn", pair.bg
    assert_in_delta 21.0, pair.ratio, 0.01
  end

  def test_token_file_without_pairs_reports_no_contrast_rows
    with_dir do |dir|
      write(dir, "tokens.css", ":root {\n  --brand: #123456;\n  --background: #ffffff;\n}\n")
      report = ColorCheck.run(dir, strict: true)
      assert_empty report.contrast
      assert_includes ColorCheck.render(report), "none declared"
      assert_equal 0, report.exit_code
    end
  end

  def test_whole_string_short_hex_is_a_strict_finding
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "a.js", "const c = dark ? '#fff' : base;\n")
      report = ColorCheck.run(dir, strict: true)
      assert_equal [ "#fff" ], report.findings.map(&:text)
      assert_equal [], report.unresolved
      refute_equal 0, report.exit_code
    end
  end

  def test_jsx_fill_expression_is_a_strict_finding
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "a.jsx", "export const I = () => <path fill={'#f00'} />;\n")
      report = ColorCheck.run(dir, strict: true)
      assert_equal 1, report.findings.size
      assert_equal 1, report.exit_code
    end
  end

  def test_json_output_shape
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS + ".x{color:red}\n")
      report = ColorCheck.run(dir)
      parsed = JSON.parse(ColorCheck.to_json_report(report))
      assert_equal %w[tokens token_errors palette contrast findings unresolved exit_code parse_errors], parsed.keys
      assert_equal File.join(dir, "tokens.css"), parsed["tokens"]
      assert_includes parsed["token_errors"].first["message"], ".x"
      assert_equal 4, parsed["palette"].size
      assert_equal %w[variant fg bg ratio status reason], parsed["contrast"].first.keys
      assert_equal %w[light dark], parsed["contrast"].map { |c| c["variant"] }
    end
  end

  def test_empty_directory_reports_no_palette_found
    with_dir do |dir|
      report = ColorCheck.run(dir)
      assert_nil report.palette
      assert_equal 0, report.exit_code
      assert_includes report.token_errors.first.message, "no token file found"
      assert_includes ColorCheck.render(report), "no palette found"
    end
  end

  def test_ordinary_rules_in_token_file_are_errors_and_still_scanned
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS + ".hero { background: linear-gradient(#fff, #000); color: #123456; }\n")
      report = ColorCheck.run(dir, strict: true)
      kinds = report.findings.map(&:kind)
      assert_includes kinds, "gradient"
      assert_includes kinds, "literal"
      assert report.findings.none? { |f| f.text.include?("--cream") }
      assert(report.token_errors.any? { |e| e.message.include?(".hero") })
      assert_equal 1, report.exit_code
    end
  end

  def test_var_cycle_resolves_to_nil_instead_of_crashing
    pair = contrast_for(":root { --background: #fff; --page-text: var(--page-text); --a: var(--b); --b: var(--a); }\n")
    assert_includes pair.reason, "cycle"
  end

  def test_final_declaration_without_semicolon_stops_at_brace
    with_dir do |dir|
      write(dir, "tokens.css", ":root { --background: #fff; --last: #555 }\n.hero { color: #abcdef; }\n")
      report = ColorCheck.run(dir, tokens_override: File.join(dir, "tokens.css"))
      assert report.findings.any? { |f| f.text.include?("#abcdef") }
      assert(report.palette.authored.any? { |a| a[:names].include?("--last") })
    end
  end
end
