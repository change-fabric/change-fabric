# frozen_string_literal: true

require "minitest/autorun"

# The hook marks a rubric reminder surfaced as soon as it returns it, so every
# OpenCode exit path from tool.execute.before must deliver it, a denial included.
class OpencodeHookContextTest < Minitest::Test
  SOURCE = File.read(File.expand_path("../extensions/opencode-cf-hooks/index.ts", __dir__))

  def before_body
    start = SOURCE.index('"tool.execute.before"')
    SOURCE[start...SOURCE.index('"tool.execute.after"', start)]
  end

  def test_denial_carries_the_rubric_reminder
    body = before_body
    deny = body.index('permissionDecision === "deny"')
    assert body.index("const reminder") < deny, "reminder must be read before the denial throws"
    assert_match(/throw new Error\(reminder \? `\$\{reason\}\\n\\n\$\{reminder\}` : reason\)/, body)
  end

  # A resumed grandchild only inherits the root's mode if every ancestor binds
  # before it does.
  def test_session_binding_walks_the_parent_chain_with_a_cycle_guard
    assert_match(/if \(parentID\) await ensureSession\(parentID, new Set\(\[ \.\.\.seen, id \]\)\)/, SOURCE)
    assert_match(/if \(seen\.has\(id\) \|\| seen\.size >= 32\) return/, SOURCE)
  end
end
