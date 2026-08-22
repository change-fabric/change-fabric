#!/usr/bin/env ruby
# frozen_string_literal: true

# Normalizes any persisted or answered merge-mode value to one of the four
# canonical slugs. Returns nil for anything it does not recognize: an
# unrecognized value is never guess-laundered into a valid mode, because the
# callers treat nil as "fail safe to local-only", which is strictly safer than
# a wrong guess.
module MergeModeSlug
  MODES = %w[local-only merge-ready admin-bypass yolo].freeze
  FALLBACK = 'local-only'

  # Strips a trailing parenthetical so an AskUserQuestion label that carried a
  # hint ("Admin bypass (recommended)") normalizes like the plain label. One
  # such value exists on disk today.
  PARENTHETICAL = /\s*\(.*\)\s*\z/

  def self.of(raw)
    slug = raw.to_s.strip
               .sub(PARENTHETICAL, '')
               .downcase
               .gsub(/[^a-z0-9]+/, '-')
               .gsub(/\A-|-\z/, '')
    MODES.include?(slug) ? slug : nil
  end
end
