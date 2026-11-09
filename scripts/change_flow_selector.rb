# frozen_string_literal: true

# Parses the text and position selector forms a flow step may use on top of
# plain Puppeteer selectors. A plain selector (CSS, or Puppeteer's own
# `::-p-text(...)` / `::-p-xpath(...)`) goes straight to waitForSelector and
# parses to nil here. The forms below compile to a locator the flow runtime
# resolves inside the page (`cfLocate`):
#
#   text=Sign in                     innermost element whose text contains it
#   text="Sign in"                   innermost element whose text is exactly it
#   button:has-text("Save")          CSS match whose text contains it
#   li:text-is("Free plan")          CSS match whose text is exactly it
#   tr.row >> nth=2                  the third CSS match (0-based; -1 is last)
#   li:has-text("Free") >> nth=0     combined
#
# Text is compared with whitespace collapsed, as a reader sees it. Anything
# else Playwright accepts (other `>>` chains, `:has-text` mid-selector, mixing
# these with `::-p-`) is refused at compile time instead of failing as a
# timeout in the browser.
module ChangeFlowSelector
  Error = Class.new(StandardError)

  NTH = /\s*>>\s*nth=(-?\d+)\s*\z/
  TEXT_ENGINE = /\Atext=(.+)\z/m
  PSEUDO = /:(text-is|has-text)\((?:"([^"]*)"|'([^']*)'|([^)"']*))\)\z/
  PLAYWRIGHT_ONLY = /:text-is\(|:has-text\(|>>|\Atext=/

  module_function

  # Returns nil for a plain selector, or { css:, hasText:, textIs:, nth: }.
  def locator(selector)
    rest, nth = split_nth(selector.to_s.strip)
    found = text_engine(rest) || pseudo(rest)
    found ||= { css: rest, hasText: nil, textIs: nil }
    if nth.nil? && found[:hasText].nil? && found[:textIs].nil?
      check_css(rest, selector) unless rest.include?('::-p-')
      return nil
    end

    check_css(found[:css], selector)
    found.merge(nth: nth)
  end

  def split_nth(selector)
    match = selector.match(NTH)
    return [ selector, nil ] unless match

    [ selector[0...match.begin(0)], Integer(match[1]) ]
  end

  def text_engine(selector)
    match = selector.match(TEXT_ENGINE)
    return nil unless match

    raw = match[1].strip
    quoted = raw.match(/\A"(.*)"\z/m) || raw.match(/\A'(.*)'\z/m)
    quoted ? text_locator(nil, text_is: quoted[1]) : text_locator(nil, has_text: raw)
  end

  def pseudo(selector)
    match = selector.match(PSEUDO)
    return nil unless match

    text = match[2] || match[3] || match[4].to_s.strip
    css = selector[0...match.begin(0)].strip
    css = nil if css.empty?
    match[1] == 'text-is' ? text_locator(css, text_is: text) : text_locator(css, has_text: text)
  end

  def text_locator(css, has_text: nil, text_is: nil)
    { css: css, hasText: has_text && squish(has_text), textIs: text_is && squish(text_is) }
  end

  def squish(text) = text.gsub(/\s+/, ' ').strip

  def check_css(css, selector)
    return if css.nil?
    raise Error, "selector #{selector.inspect}: an empty selector before >> nth" if css.empty?
    raise Error, "selector #{selector.inspect}: :text-is/:has-text/>> nth cannot combine with ::-p- selectors" if css.include?('::-p-')
    return unless css.match?(PLAYWRIGHT_ONLY)

    raise Error, "selector #{selector.inspect}: only one trailing :text-is/:has-text and one trailing >> nth=N are supported"
  end
end
