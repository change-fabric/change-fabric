# frozen_string_literal: true

require 'minitest/autorun'

# Window ids may start with a digit (ID_RE in walkthrough_environment.rb), so
# wm.js must never interpolate a raw id into an id selector.
class DesktopWmSelectorTest < Minitest::Test
  WM = File.expand_path('../skills/prototype/fixtures/desktop/wm.js', __dir__)

  def test_no_raw_id_interpolated_into_id_selector
    src = File.read(WM)
    raw = src.scan(/#\$\{(?!CSS\.escape\()[^}]*\}/)
    assert_empty raw, "unescaped id selectors in wm.js: #{raw.inspect}"
  end

  def test_each_suffix_selector_is_escaped
    src = File.read(WM)
    %w[-lines -tree -download-bar].each do |suffix|
      assert_includes src, "CSS.escape(", "missing escape for #{suffix}"
      assert_match(/CSS\.escape\(\w+ \+ '#{suffix}'\)/, src)
    end
  end
end
