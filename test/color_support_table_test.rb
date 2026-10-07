# frozen_string_literal: true

require "tmpdir"
require_relative "test_helpers"
require_relative "#{File.expand_path('../scripts', __dir__)}/color_check"

# Executable form of the "Token file" and "Stray scan" contract in
# skills/color/SKILL.md: one fixture per grammar bullet.
class ColorSupportTableTest < Minitest::Test
  def read_tokens(css)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tokens.css")
      File.write(path, css)
      ColorTokens.read(path)
    end
  end

  def assert_token_ok(css)
    result = read_tokens(css)
    assert_empty result.errors, css
    result
  end

  def assert_token_error(css, fragment)
    errors = read_tokens(css).errors
    refute_empty errors, css
    assert(errors.any? { |e| e.message.include?(fragment) && e.line.positive? }, errors.inspect)
  end

  def classes(path, text)
    ColorScan.classify_all(path, text)
  end

  def kinds(path, text)
    ColorScan.findings_for(path, text, token_file: nil).map(&:kind)
  end

  # --- Token file: location ---------------------------------------------------

  def test_token_file_path_list_and_override
    Dir.mktmpdir do |root|
      assert_kind_of ColorTokens::Error, ColorTokens.locate(root, nil)
      FileUtils.mkdir_p(File.join(root, "src/app"))
      File.write(File.join(root, "tokens.css"), ":root{--a:#000}")
      assert_equal File.join(root, "tokens.css"), ColorTokens.locate(root, nil)
      File.write(File.join(root, "src/app/globals.css"), ":root{--a:#000}")
      assert_kind_of ColorTokens::Error, ColorTokens.locate(root, nil)
      assert_equal "x.css", ColorTokens.locate(root, "x.css")
    end
  end

  # --- Token file: top level --------------------------------------------------

  def test_token_file_top_level
    assert_token_ok("@import 'tailwindcss';\n@custom-variant dark (&:is(.dark *));\n:root{--a:#000}")
    assert_token_ok("@layer base { :root{--a:#000} .dark{--a:#fff} }")
    assert_token_ok("@layer { :root{--a:#000} }")
    assert_token_ok("@theme { --a: #000; }")
    assert_token_error("@layer a { @layer b { :root{--a:#000} } }", "@layer")
    assert_token_error("@supports (color: red) { :root{--a:#000} }", "@supports")
    assert_token_error("@media print { :root{--a:#000} }", "@media")
  end

  # --- Token file: selectors --------------------------------------------------

  def test_token_file_selectors
    [ ".dark", ":root.dark", "[data-theme=dark]", "[data-theme=\"dark\"]", "[data-theme='dark']",
      ":root[data-theme=\"dark\"]" ].each do |sel|
      result = assert_token_ok(":root{--a:#000}\n#{sel}{--a:#fff}")
      assert_equal "#fff", result.variants[:dark]["--a"], sel
    end
    assert_token_ok(":root{--a:#000}\n.dark, [data-theme=dark]{--a:#fff}")
    assert_token_error(":root{--a:#000}\n:root, .dark{--a:#fff}", ":root, .dark")
    assert_token_error("html{--a:#000}", "html")
    assert_token_error(":root{--a:#000}\n:root .dark{--a:#fff}", ":root .dark")
    assert_token_error(":root{--a:#000}\n.dark .card{--a:#fff}", ".dark .card")
    assert_token_error(":root{--a:#000}\n.dark > .card{--a:#fff}", ">")
  end

  # --- Token file: prefers-color-scheme ---------------------------------------

  def test_token_file_prefers_color_scheme
    dark = assert_token_ok(":root{--a:#000}\n@media (prefers-color-scheme: dark){:root{--a:#fff}}")
    assert_equal "#fff", dark.variants[:dark]["--a"]
    assert_token_ok(":root{--a:#000}\n@media (prefers-color-scheme: light){:root{--b:#111}}")
    assert_token_error(":root{--a:#000}\n@media (prefers-color-scheme: light){:root{--a:#111}}", "--a")
    assert_token_error(":root{--a:#000}\n@media (prefers-color-scheme: dark){.dark{--a:#fff}}", ".dark")
  end

  # --- Token file: declarations -----------------------------------------------

  def test_token_file_declarations
    assert_token_error(":root{--a:#000; color: red}", "color")
    assert_token_error(":root{--a:#000; @apply bg-black}", "@apply")
  end

  # --- Token file: values -----------------------------------------------------

  def test_token_file_values
    result = assert_token_ok(":root{--a:#000;--b:rgb(1 2 3);--c:hsl(0 0% 0%);--d:red;" \
                             "--e:var(--a);--f:color-mix(in srgb, var(--a) 50%, #fff);" \
                             "--radius:0.5rem;--g:oklch(0.2 0 0)}")
    assert_equal "0.5rem", result.variants[:light]["--radius"]
    assert_token_ok(":root{--a:#000;--b:#111;--c:#222;--d:#333;--error:#f00}")
    assert_token_error(":root{--a:#000;--b:#111;--c:#222;--d:#333;--e:#444}", "palette")
  end

  # --- Token file: dark redefinition ------------------------------------------

  def test_token_file_dark_redefinition
    assert_token_error(":root{--a:#000}\n.dark{--b:#fff}", "--b")
    assert_token_error(":root{--a:#000}\n.dark{--a:#fff}\n[data-theme=dark]{--a:#eee}", "--a")
    assert_token_ok(":root{--a:#000}\n.dark{--a:#fff}\n[data-theme=dark]{--a:#fff}")
  end

  # --- Contrast: the fixed pair rule ------------------------------------------

  def test_contrast_pair_rule
    pairs = ColorTokens.pairs("--background" => "#fff", "--card" => "#000", "--card-foreground" => "#fff",
                              "--muted-ink" => "#000", "--fg" => "#000")
    assert_includes pairs, %w[--card-foreground --card]
    assert_includes pairs, %w[--muted-ink --background]
  end

  # --- Stray scan: surfaces ---------------------------------------------------

  def test_stray_css_declaration_values_and_apply
    [ ".a { color: #abc; }", ".a { color: rgb(1 2 3); }", ".a { color: red; }" ].each do |css|
      assert_equal [ :finding ], classes("a.css", css).map(&:last), css
    end
    assert_equal [ "tailwind" ], kinds("a.css", ".a { @apply bg-red-500; }")
  end

  def test_stray_markup_surfaces
    assert_equal [ "literal" ], kinds("a.html", "<style>.a { color: #abcdef; }</style>")
    assert_equal [ "literal" ], kinds("a.html", '<p style="color: #abc">x</p>')
    assert_equal [ "literal" ], kinds("a.html", '<path fill="#abcdef"/>')
    assert_equal [ "literal" ], kinds("a.html", '<path stroke="red"/>')
    assert_equal [ "tailwind" ], kinds("a.html", '<p class="text-red-500">x</p>')
    assert_equal [], kinds("a.jsx", '<p className="bg-red-500" />')
  end

  def test_stray_script_whole_string_literals
    [ "x('#abcdef');", "x('rgb(1 2 3)');", "x('hsla(0, 0%, 0%, 1)');" ].each do |js|
      assert_equal [ :finding ], classes("a.js", js).map(&:last), js
    end
    assert_equal [ "literal" ], kinds("a.html", "<script>x('#abcdef');</script>")
  end

  def test_stray_script_short_hex_whole_string_is_a_finding
    assert_equal [ [ "#cafe", :finding ] ], classes("a.js", "document.querySelector('#cafe');")
  end

  # --- Stray scan: literal forms and exempt keywords --------------------------

  def test_stray_literal_forms
    assert_equal [ :finding ], classes("a.css", "a{text-decoration:underline red}").map(&:last)
    assert_equal [], classes("a.css", "a{animation-name:red}")
    assert_equal [ [ "red", :unresolved ] ], classes("a.css", "a{foo-bar:red}")
    [
      ".a { color: transparent; border-color: currentColor; color: inherit; }",
      ".a { color: initial; color: unset; color: revert; outline: none; }"
    ].each { |css| assert_equal [], classes("a.css", css), css }
  end

  # --- Stray scan: Tailwind rule ----------------------------------------------

  def test_stray_tailwind_rule
    tokens = Set["--brand"]
    { "hover:bg-red-500/50" => :finding, "!bg-black" => :finding, "md:dark:text-white" => :finding,
      "bg-[#abc]" => :finding, "text-[rgb(1,2,3)]" => :finding, "border-[color:#fff]" => :finding,
      "decoration-sky-500" => :finding, "bg-current" => :exempt, "bg-brand" => :exempt,
      "bg-[var(--brand)]" => :exempt, "bg-[var(--nope)]" => :unresolved, "bg-nope" => :unresolved }.each do |cls, want|
      got = ColorTailwind.findings(cls, tokens: tokens)
      assert_equal [ [ cls, want ] ], got.map { |f| [ f.text, f.status ] }, cls
    end
    %w[text-sm border-2 ring-1 w-[#abc] bg-[3px]].each do |cls|
      assert_empty ColorTailwind.findings(cls, tokens: tokens), cls
    end
  end

  # --- Stray scan: not scanned ------------------------------------------------

  def test_stray_not_scanned
    [ "const u = '/page#feed';", "const css = `.a { color: #abcdef }`;", "// #abcdef" ].each do |js|
      assert_equal [], classes("a.js", js), js
    end
    assert_equal [], classes("a.html", "<p>red #abcdef prose</p>")
    assert_equal [], classes("icon.svg", '<svg><path fill="#abcdef"/></svg>')
    assert_equal [], classes("a.scss", "$brand: #abcdef;").reject { |_, c| c == :finding }
  end

  def test_stray_clsx_arguments_not_scanned
    assert_equal [], classes("a.jsx", "clsx('bg-red-500', ok && 'text-white')")
  end

  # --- The contract sections exist --------------------------------------------

  def test_contract_sections_exist
    skill = File.read(File.expand_path("../skills/color/SKILL.md", __dir__))
    [ "### Token file", "### Stray scan", "### Review triage" ].each { |h| assert_includes skill, h }
    refute_includes skill, "| Area | Supported |"
  end
end
