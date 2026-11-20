# frozen_string_literal: true

require "minitest/autorun"
require "cgi"
require "json"
require_relative "../approval_console/infra/lambda/pages"
require_relative "../scripts/approval_console/canonical"

# Structural tests for the approval console pages, one per display contract in
# the approval-console-design plan. They read the server-rendered markup only;
# the page script's behaviour is tested in approval_console_transitions_test.rb.
class ApprovalConsolePagesTest < Minitest::Test
  Canonical = ApprovalConsole::Canonical
  TYPES = %w[step override prod-op money carve-out release].freeze
  FIXTURES = File.expand_path("fixtures/approval_console", __dir__)
  HIDDEN = /[​-‏‪-‮⁦-⁩﻿]/
  NONCE = "test-nonce-123"

  # ----- helpers ---------------------------------------------------------

  def attrs(type) = JSON.parse(File.read(File.join(FIXTURES, "#{type}.json")))

  def stored(type, **changes) = Canonical.build(attrs(type).merge(changes.transform_keys(&:to_s)))

  def render(type, status: "pending", **changes)
    string = stored(type, **changes)
    ConsolePages.approve(NONCE, string, JSON.parse(string), status, [ "cred-1" ])
  end

  def island(html) = html[%r{<script type="application/json" id="d"[^>]*>(.*?)</script>}m, 1]

  def without_island(html) = html.sub(%r{<script type="application/json" id="d"[^>]*>.*?</script>}m, "")

  def zone(html, name) = html[%r{<(section|details)\b[^>]*data-zone="#{name}"[^>]*>.*?</\1>}m]

  def fields(html) = html.scan(%r{<(\w+) data-field="([^"]*)"[^>]*>([^<]*)</\1>}).map { |_, path, text| [ CGI.unescapeHTML(path), CGI.unescapeHTML(text) ] }

  def neutral(text) = text.to_s.gsub(HIDDEN) { |char| format("[U+%04X]", char.ord) }

  def text_of(html, pattern) = CGI.unescapeHTML(html[pattern, 1].to_s)

  def leaf_paths(value, path = [])
    case value
    when Hash then value.empty? ? [ [ path, value ] ] : value.flat_map { |key, item| leaf_paths(item, path + [ key ]) }
    when Array then value.empty? ? [ [ path, value ] ] : value.each_with_index.flat_map { |item, i| leaf_paths(item, path + [ i ]) }
    else [ [ path, value ] ]
    end
  end

  # The zone each leaf belongs to, written out independently of pages.rb.
  def expected_zone(type, path)
    key = path.join(".")
    return :technical if key.match?(/\A(machine_id|request_id|profile|v|pr_url)\z/)
    return :verified if key.match?(/\A(repo|sha|type|created_at|expires_at)\z/)

    case type
    when "step" then key.match?(/\Aitems\.\d+\.(step|digest|base_fields)(\.|\z)/) ? :verified : :agent
    when "override" then key == "scope" ? :verified : :agent
    when "prod-op", "money" then key.start_with?("argv.") ? :verified : :agent
    when "carve-out" then key == "base" || key.start_with?("files.") ? :verified : :agent
    when "release" then :verified
    end
  end

  def expected_text(path, value)
    return "format v#{value}" if path == [ "v" ]

    neutral(value.nil? ? "none" : value.to_s)
  end

  # ----- 1. presented fields ---------------------------------------------

  def test_every_leaf_has_exactly_one_primary_presentation_in_its_zone
    TYPES.each do |type|
      string = stored(type)
      html = render(type)
      found = fields(html)
      leaves = leaf_paths(JSON.parse(string))
      assert_equal leaves.size, found.size, "#{type}: one data-field element per leaf"
      leaves.each do |path, value|
        key = neutral(path.join("."))
        matches = found.select { |found_path, _| found_path == key }
        assert_equal 1, matches.size, "#{type}: #{key} is presented once"
        assert_equal expected_text(path, value), matches.first.last, "#{type}: #{key} display form"
        in_zone = fields(zone(html, expected_zone(type, path)).to_s).count { |found_path, _| found_path == key }
        assert_equal 1, in_zone, "#{type}: #{key} sits in the #{expected_zone(type, path)} zone"
      end
    end
  end

  def test_technical_echoes_are_labelled_and_carry_no_data_field
    html = render("carve-out")
    technical = zone(html, "technical")
    assert_includes technical, "type (raw, echo)"
    assert_includes technical, "created_at (raw, echo)"
    refute(fields(technical).any? { |path, _| %w[type created_at].include?(path) }, "echoes are not primary presentations")
    assert_includes fields(technical).map(&:last), "format v1"
    assert_includes fields(technical).map(&:last), "none"
  end

  def test_the_files_list_shows_eight_then_a_collapse_for_the_rest
    html = render("carve-out")
    verified = zone(html, "verified")
    assert_includes verified, "12 files changed"
    assert_includes verified, "Show 4 more files"
    assert_equal 12, fields(verified).count { |path, _| path.start_with?("files.") }
    assert_equal 8, verified.split("<details>").first.scan("data-field=\"files.").size
  end

  def test_a_step_shows_current_values_as_verified_and_proposed_values_as_agent_text
    html = render("step")
    assert_includes zone(html, "verified"), "Current values"
    assert_includes zone(html, "agent"), "Proposed values, written by the agent"
    assert_includes zone(html, "agent"), "Current: 10"
    assert_equal "12", fields(zone(html, "agent")).to_h["items.0.fields.rows"]
    assert_equal "10", fields(zone(html, "verified")).to_h["items.0.base_fields.rows"]
  end

  # ----- 2. agent placement ----------------------------------------------

  def test_agent_values_appear_only_in_the_agent_zone_the_signed_text_and_the_data_island
    TYPES.each do |type|
      markers = File.read(File.join(FIXTURES, "#{type}.json")).scan(/AGENTMARK-[\w-]+/).uniq
      html = render(type)
      rest = html.sub(zone(html, "agent"), "").sub(zone(html, "signed"), "").sub(%r{<script type="application/json" id="d"[^>]*>.*?</script>}m, "")
      markers.each do |marker|
        assert_includes zone(html, "agent"), marker, "#{type}: #{marker} is in the agent zone"
        refute_includes rest, marker, "#{type}: #{marker} appears nowhere else"
      end
      assert_includes zone(html, "agent"), "No agent text for this request" if markers.empty?
    end
  end

  def test_the_agent_zone_is_framed_by_markup_outside_agent_control
    html = render("carve-out")
    assert_includes zone(html, "agent"), "Written by the requesting agent, unverified"
    assert_includes zone(html, "verified"), "Verified facts"
  end

  def test_no_link_target_carries_agent_text
    TYPES.each do |type|
      hrefs = render(type).scan(/href="([^"]*)"/).flatten
      assert(hrefs.none? { |href| href.include?("AGENTMARK") }, "#{type}: #{hrefs}")
    end
  end

  # ----- 3. neutralization -----------------------------------------------

  def test_hidden_code_points_show_as_markers_everywhere_but_the_data_island
    TYPES.each do |type|
      refute_match HIDDEN, without_island(render(type)), "#{type}: no raw bidi or zero-width code point outside the island"
    end
    step = render("step")
    assert_includes zone(step, "agent"), "[U+202E]"
    assert_includes zone(step, "agent"), "[U+200D]"
    assert_includes zone(step, "signed"), "[U+202E]"
    assert_includes zone(step, "signed"), "Hidden characters are shown as [U+XXXX]; the hash is over the original bytes"
    assert_includes zone(render("prod-op"), "agent"), "[U+202E]Safe."
    refute_includes zone(render("release"), "signed"), "Hidden characters are shown"
  end

  def test_free_verified_strings_are_neutralized_too
    html = render("carve-out", base: "ma‮in", files: [ "a​b.rb", "c.rb" ])
    refute_match HIDDEN, without_island(html)
    assert_includes zone(html, "verified"), "ma[U+202E]in"
    assert_includes zone(html, "verified"), "a[U+200B]b.rb"
  end

  def agent_fields(**changes) = fields(zone(render("carve-out", **changes), "agent")).to_h

  def test_neutralization_covers_every_listed_range_and_its_edges
    codes = [ 0x200B, 0x200F, 0x202A, 0x202E, 0x2066, 0x2069, 0xFEFF ]
    text = codes.map { |code| [ code ].pack("U") }.join
    shown = agent_fields(summary: "a#{text}b")["summary"]
    assert_equal "a#{codes.map { |code| format('[U+%04X]', code) }.join}b", shown
    outside = [ 0x200A, 0x2010, 0x2029, 0x202F, 0x2065, 0x206A, 0xFEFE ].map { |code| [ code ].pack("U") }.join
    assert_equal outside, agent_fields(summary: outside)["summary"], "code points next to the ranges are left alone"
  end

  def test_markers_at_string_boundaries_and_adjacent
    assert_equal "[U+202E]x[U+200D]", agent_fields(summary: "\u202Ex\u200D")["summary"]
    assert_equal "[U+200B][U+200B][U+200B]", agent_fields(summary: "\u200B\u200B\u200B")["summary"]
    assert_equal "[U+FEFF]", agent_fields(pr_title: "\uFEFF")["pr_title"]
  end

  def test_hash_keys_and_nested_agent_values_are_neutralized_at_any_depth
    items = [ { "step" => "s", "base_fields" => nil, "fields" => { "k\u202Ey" => { "d\u200Dp" => [ "v\u2066", [ "w\u200F" ], {} ], "e" => "" } } } ]
    html = render("step", items: items)
    refute_match HIDDEN, without_island(html)
    agent = zone(html, "agent")
    assert_includes agent, "k[U+202E]y.d[U+200D]p.0"
    assert_equal "v[U+2066]", fields(agent).to_h["items.0.fields.k[U+202E]y.d[U+200D]p.0"]
    assert_equal "w[U+200F]", fields(agent).to_h["items.0.fields.k[U+202E]y.d[U+200D]p.1.0"]
    assert_equal "", fields(agent).to_h["items.0.fields.k[U+202E]y.e"]
  end

  def test_the_signed_text_pre_neutralizes_the_whole_body_and_notes_it_only_when_needed
    html = render("carve-out", summary: "x\u202Ey")
    assert_includes zone(html, "signed"), "x[U+202E]y"
    assert_includes zone(html, "signed"), "Hidden characters are shown"
    refute_includes zone(render("carve-out"), "signed"), "Hidden characters are shown"
  end

  # ----- long agent text -------------------------------------------------

  def test_a_long_agent_leaf_shows_600_characters_and_keeps_the_rest_in_the_dom
    text = "AGENTMARK-" + ("0123456789" * 70)
    html = render("carve-out", summary: text)
    agent = zone(html, "agent")
    assert_equal text[0, 600], agent[%r{<q data-field="summary">(.*?)</q>}m, 1]
    rest = text[600..]
    assert_includes agent, %(<details class="more" data-rest="summary"><summary>Show the rest (#{rest.length} more characters)</summary><q>#{rest}</q></details>)
    assert_equal text, agent[%r{<q data-field="summary">(.*?)</q>}m, 1] + agent[%r{data-rest="summary"><summary>[^<]*</summary><q>(.*?)</q>}m, 1]
    assert_equal 1, html.scan(%(data-field="summary")).size
  end

  def test_the_collapse_boundary_is_exactly_600_characters
    exact = "a" * 600
    refute_includes agent_zone_of(exact), "Show the rest"
    over = agent_zone_of("a" * 601)
    assert_includes over, "Show the rest (1 more characters)"
  end

  def agent_zone_of(text) = zone(render("carve-out", summary: text), "agent")

  def test_the_collapse_cuts_before_neutralizing_so_a_marker_is_never_split
    text = ("a" * 599) + "\u202E" + "tail"
    html = render("carve-out", summary: text)
    agent = zone(html, "agent")
    assert_includes agent, %(<q data-field="summary">#{'a' * 599}[U+202E]</q>)
    assert_includes agent, "<q>tail</q>"
    refute_match HIDDEN, without_island(html)
  end

  def test_long_text_in_a_nested_step_value_collapses_too_and_verified_values_never_do
    long = "z" * 700
    html = render("step", items: [ { "step" => "s", "base_fields" => { "k" => long }, "fields" => { "k" => long } } ])
    assert_includes zone(html, "agent"), "Show the rest (100 more characters)"
    refute_includes zone(html, "verified"), "Show the rest"
    assert_includes zone(html, "verified"), long
  end

  # ----- in-app browser hint ---------------------------------------------

  def test_the_in_app_browser_hint_is_hidden_markup_the_script_reveals_above_the_form
    html = render("carve-out")
    assert_includes html, '<p id="inapp" class="hint" hidden>Open in Safari for passkeys</p>'
    assert_operator html.index('id="inapp"'), :<, html.index('<form id="approve">')
    refute_includes render("carve-out", status: "expired"), "Open in Safari for passkeys"
    js = ConsolePages::APPROVE_JS
    [ "FBAN", "Instagram", "MicroMessenger", "hint.hidden=false" ].each { |needle| assert_includes js, needle }
  end

  # ----- 4. data island --------------------------------------------------

  def test_the_data_island_holds_the_stored_body_byte_for_byte
    TYPES.each do |type|
      string = stored(type)
      html = render(type)
      data = JSON.parse(island(html))
      assert_equal string, data["body"], "#{type}: island body is the stored string"
      assert_equal [ "cred-1" ], data["credentials"]
    end
    assert_includes JSON.parse(island(render("prod-op")))["body"], "‮"
    assert_includes JSON.parse(island(render("step")))["body"], "‮"
    refute_includes island(render("carve-out", summary: "</script><b>")), "</script>"
  end

  # ----- 5. markup safety ------------------------------------------------

  def all_pages
    pages = TYPES.flat_map { |type| %w[pending expired approved].map { |status| render(type, status: status) } }
    pages + [ ConsolePages.enroll(NONCE, [ "c" ], "id", "src", false), ConsolePages.enroll(NONCE, [], "", "", true),
              ConsolePages.register(NONCE), ConsolePages.notice(NONCE, "Not found", "No such request.") ]
  end

  def test_no_inline_style_attribute_no_external_asset_and_every_tag_carries_the_nonce
    all_pages.each do |html|
      refute_match(/\sstyle=/i, html)
      refute_match(/<link\b/i, html)
      refute_match(/@import|url\(/i, html)
      refute_match(%r{\b(?:src|action)="https?:}i, html)
      tags = html.scan(/<(?:script|style)\b[^>]*>/)
      refute_empty tags
      assert(tags.all? { |tag| tag.include?(%(nonce="#{NONCE}")) }, tags.inspect)
    end
  end

  def test_agent_markup_is_escaped
    html = render("carve-out", summary: %(<img src=x onerror=alert(1)> & "q"), pr_title: "<b>bold</b>")
    refute_includes html, "<img src=x"
    refute_includes html, "<b>bold</b>"
    assert_includes zone(html, "agent"), "&lt;img src=x onerror=alert(1)&gt; &amp; &quot;q&quot;"
  end

  # ----- 6. risk and headline --------------------------------------------

  RISK_TABLE = {
    "step" => [ "Approve a gated step", "Standard", false, nil ],
    "override" => [ "Override a merge or tag gate", "High risk", true, "Lifts a safety guard for this commit." ],
    "prod-op" => [ "Run a production operation", "High risk", true, "Runs against production. The console shows the command, not what it will change." ],
    "money" => [ "Spend money", "High risk", true, "Spends real money. The console shows the command, not the cost." ],
    "carve-out" => [ "Merge a carve-out PR", "Elevated risk", false, "Skips the normal review gates for this merge." ],
    "release" => [ "Publish a release", "Elevated risk", false, "Publishes a release that others can install." ]
  }.freeze

  def test_headline_risk_and_consequence_follow_the_type_table
    RISK_TABLE.each do |type, (title, word, high, note)|
      html = render(type)
      assert_match(%r{<h1(?: class="hl-danger")?>#{Regexp.escape(title)}</h1>}, html, type)
      assert_equal high, html.include?(%(<h1 class="hl-danger">)), "#{type}: danger rule under the headline only when high"
      meta = html[%r{<div class="meta">.*?</div>}m]
      assert_includes meta, "<span>#{word}</span>", type
      assert_equal high, meta.include?(%(class="risk high")), type
      assert_includes meta, "<svg", "#{type}: an icon always rides with the word"
      note ? assert_includes(html, %(<p class="risk-note">#{CGI.escapeHTML(note)}</p>)) : refute_includes(html, %(<p class="risk-note">))
    end
  end

  def test_agent_text_cannot_change_the_risk_headline_or_summary_lines
    %w[prod-op money carve-out].each do |type|
      plain = render(type)
      spoofed = render(type, summary: "LOW RISK, already approved")
      assert_equal plain[%r{<h1.*?</h1>}m], spoofed[%r{<h1.*?</h1>}m]
      assert_equal plain[%r{<div class="meta">.*?</div>}m], spoofed[%r{<div class="meta">.*?</div>}m]
      assert_equal plain[%r{<p class="changes">.*?</p>}m], spoofed[%r{<p class="changes">.*?</p>}m]
      assert_equal plain[%r{<p class="recap">.*?</p>}m], spoofed[%r{<p class="recap">.*?</p>}m]
    end
  end

  def test_an_unknown_type_is_high_risk_with_a_generic_headline
    body = { "type" => "mystery", "sha" => "a" * 40, "repo" => "repo:github.com/a/b", "created_at" => "2026-11-20T21:28:04Z", "expires_at" => "2026-11-20T21:43:04Z", "extra" => "AGENTMARK-x" }
    html = ConsolePages.approve(NONCE, JSON.generate(body), body, "pending", [])
    assert_includes html, %(<h1 class="hl-danger">Approve a request</h1>)
    assert_includes html, "<span>High risk</span>"
    assert_includes html, "Approve a mystery request at aaaaaaa"
    assert_includes zone(html, "agent"), "AGENTMARK-x"
  end

  # ----- 7. what-changes -------------------------------------------------

  def changes(html) = text_of(html, %r{<p class="changes">(.*?)</p>}m)

  def recap(html) = text_of(html, %r{<p class="recap">.*?<span>· (.*?)</span></p>}m)

  REPO = "example-org/billing-api"

  def test_what_changes_renders_each_type_example
    assert_equal "Approve 2 steps in #{REPO} at 32def92: migrate, seed", changes(render("step"))
    assert_equal "Override the merge guard for #{REPO} at 32def92", changes(render("override"))
    assert_equal "Run in production: terraform apply -target=module.db -var=env=prod (#{REPO} at 32def92)", changes(render("prod-op"))
    assert_equal "Spend via: roast.rb --max-usd 10 (#{REPO} at 32def92)", changes(render("money"))
    assert_equal "Merge PR #612 into main at 32def92 (12 files)", changes(render("carve-out"))
    assert_equal "Publish skills/v1.4.0 at 9f1c2ab", changes(render("release"))
  end

  def test_what_changes_fallbacks
    scoped = attrs("override").tap { |a| a.delete("scope") }
    string = Canonical.build(scoped)
    html = ConsolePages.approve(NONCE, string, JSON.parse(string), "pending", [])
    assert_equal "Override the merge and tag guards for #{REPO} at 32def92", changes(html)
    assert_equal "Override · merge+tag · 32def92", recap(html)
    assert_includes zone(html, "verified"), "merge and tag guards"

    other = render("carve-out", pr_url: "https://github.com/someone/else/pull/5")
    assert_equal "Merge a PR into main at 32def92 (12 files)", changes(other)
    assert_equal "Carve-out · PR #? · 32def92", recap(other)

    long = render("prod-op", argv: [ "echo", "x" * 100 ])
    assert_equal "Run in production: #{"echo #{"x" * 100}"[0, 80]}... (#{REPO} at 32def92)", changes(long)
    assert_includes zone(long, "verified"), "x" * 100, "the full argv stays in the verified zone"

    steps = ("a".."h").map { |c| { "step" => c * 10, "base_fields" => nil, "fields" => {} } }
    assert_equal "Approve 8 steps in #{REPO} at 32def92: #{(%w[a b c d e].map { |c| c * 10 }).join(", ")} and 3 more", changes(render("step", items: steps))
    one = render("step", items: [ steps.first ])
    assert_equal "Approve 1 step in #{REPO} at 32def92: aaaaaaaaaa", changes(one)
  end

  def test_the_phone_recap_leads_with_the_risk_and_shows_signed_fields
    assert_equal "Step · 2 · 32def92", recap(render("step"))
    assert_equal "Override · merge · 32def92", recap(render("override"))
    assert_equal "terraform apply -target=module.db -var=env=prod", recap(render("prod-op"))
    assert_equal "roast.rb --max-usd 10", recap(render("money"))
    assert_equal "Carve-out · PR #612 · 32def92", recap(render("carve-out"))
    assert_equal "Release · skills/v1.4.0", recap(render("release"))
    assert_includes render("prod-op")[%r{<p class="recap">.*?</p>}m], %(class="risk high")
  end

  # ----- 8. form ---------------------------------------------------------

  def test_one_code_field_and_one_approve_button_in_one_form
    TYPES.each do |type|
      html = render(type)
      assert_equal 1, html.scan('id="totp"').size
      assert_equal 1, html.scan('id="go"').size
      assert_equal 1, html.scan('<form id="approve">').size
      assert_equal 1, html.scan("<form").size
    end
    html = render("carve-out")
    %w[inputmode="numeric" autocomplete="one-time-code" maxlength="6" pattern="[0-9]{6}" enterkeyhint="go"].each { |attribute| assert_includes html, attribute }
    assert_includes html, '<label class="vis-label" for="totp">Authenticator code</label>'
    refute_match(/<form[^>]*action=/, html)
    assert_includes html, "Approving needs JavaScript and a passkey. Use the terminal fallback instead."
  end

  def test_the_bar_is_fixed_on_small_screens_with_safe_area_insets
    css = ConsolePages::CSS
    assert_includes css, "--bar-h: 9rem"
    assert_match(/max-width: 39\.99rem\) \{.*form#approve \{\s*position: fixed;.*env\(safe-area-inset-bottom\)/m, css)
    assert_includes render("carve-out"), '<body class="has-bar">'
    refute_includes render("carve-out", status: "expired"), %(<body class="has-bar">)
  end

  # ----- 9. tokens -------------------------------------------------------

  def declarations(block) = block.to_s.scan(/(--[\w-]+):\s*([^;]+);/).to_h { |name, value| [ name, value.gsub(/\s+/, " ").strip ] }

  def test_the_authored_colors_and_derived_tokens_match_the_site_styles
    site = File.read(File.expand_path("../site/src/styles.css", __dir__))
    css = ConsolePages::CSS
    site_light = declarations(site[/:root\[data-theme="light"\] \{(.*?)\n\}/m, 1])
    site_dark = declarations(site[/prefers-color-scheme: dark\) \{\s*:root:not\(\[data-theme="light"\]\) \{(.*?)\n  \}/m, 1])
    light = declarations(css[/:root \{(.*?)\n\}/m, 1])
    dark = declarations(css[/prefers-color-scheme: dark\) \{\n  :root \{(.*?)\n  \}/m, 1])
    %w[--cream --plum --lilac --sage --bg --surface --code-bg --border --border-strong --text --muted --accent --btn --btn-text].each do |name|
      assert_equal site_light.fetch(name), light.fetch(name), "light #{name}"
    end
    (dark.keys - %w[--danger]).each { |name| assert_equal site_dark.fetch(name), dark.fetch(name), "dark #{name}" }
    assert_equal "#b0182c", light.fetch("--danger")
    assert_equal "#ff9b9b", dark.fetch("--danger")
  end

  def test_presented_values_keep_newlines_and_repeated_spaces
    assert_includes ConsolePages::CSS, "[data-field] { white-space: pre-wrap; }"
    html = render("step", items: [ { "step" => "run", "base_fields" => { "run" => "a\n  b" }, "fields" => { "run" => "x\n  y" } } ])
    assert_includes html, %(<q data-field="items.0.fields.run">x\n  y</q>)
    assert_includes html, %(<code data-field="items.0.base_fields.run">a\n  b</code>)
  end

  def test_the_danger_token_is_used_only_for_the_high_risk_signals
    uses = ConsolePages::CSS.lines.grep(/var\(--danger\)/)
    assert_equal 2, uses.size
    assert(uses.all? { |line| line.include?(".hl-danger") || line.include?(".risk.high") })
  end

  # ----- states ----------------------------------------------------------

  def test_each_server_state_renders_its_table_row
    pending = render("carve-out")
    assert_includes pending, '<div id="result" class="status" role="status" data-kind="info" hidden>'
    assert_includes pending, "Not approving? Close this page. It expires at"
    assert_includes pending, "Expires at <time"

    expired = render("carve-out", status: "expired")
    assert_includes expired, "This request expired at <time"
    assert_includes expired, "Ask the agent for a new one."
    refute_includes expired, 'id="go"'
    refute_includes expired, "Not approving?"
    assert_includes expired, "<h1"

    approved = render("carve-out", status: "approved")
    assert_includes approved, "Already approved."
    refute_includes approved, 'id="go"'

    other = render("carve-out", status: "weird <b>")
    assert_includes other, "This request is weird &lt;b&gt;."
    refute_includes other, "weird <b>"
  end

  def test_the_page_script_covers_every_client_row_of_the_state_table
    js = ConsolePages::APPROVE_JS
    [ "That code did not match. Wait for the next code and try again.",
      "The passkey was not accepted. Try again, or use the terminal fallback.",
      "Too many failed tries. Locked until ", "The console is busy. Try again in a moment.",
      "Passkey cancelled. Tap Approve to try again.", "This browser cannot use passkeys. Open the link in Safari or use the terminal fallback.",
      "This request was already approved elsewhere. Nothing more to do.", "That code was already used. Wait for the next code and try again.", "Expiring now", "Waiting for your passkey",
      "left<-60000", "NotAllowedError" ].each { |needle| assert_includes js, needle }
    refute_match(/test|preview|location\.hash/i, js, "no test mode in the page script")
  end

  # ----- other pages -----------------------------------------------------

  def test_enroll_register_and_notice_share_the_layout
    [ ConsolePages.enroll(NONCE, [ "c" ], "id", "src", false), ConsolePages.register(NONCE), ConsolePages.notice(NONCE, "Not found", "No such <request>.") ].each do |html|
      assert_includes html, '<main class="page">'
      assert_includes html, "--danger"
      assert_includes html, "<h1>"
    end
    assert_includes ConsolePages.notice(NONCE, "Not found", "No such <request>."), "No such &lt;request&gt;."
    assert_includes ConsolePages.register(NONCE), 'id="msg" role="status"'
  end
end
