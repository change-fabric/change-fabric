# frozen_string_literal: true

require 'json'
require_relative 'prototype_ux_lint'

# The free clip check for cf:walkthrough. The capture writes boxes.json beside
# a scene's frames: for every captured frame, the post-transform box (after
# camera zoom, fit_view, and element scale) of each visible text and node,
# the text's rendered size, and whether it overflows its own box. This check
# reads every frame, not keyframes, and refuses:
#
# - a box that crosses the frame edge or the safe area (a 5 percent inset);
# - a text that overflows its box (cut or ellipsized inside it);
# - a text whose size in final 1080p output pixels is under the label
#   minimum. A layout that only fits by shrinking is refused, never shrunk:
#   the message names the content to split into another scene.
#
# Fill (the content's bounding box over the frame) outside 20 to 70 percent
# at the scene's fullest frame is a warning. Each element is reported once
# per reason, at the first frame it happens.
module WalkthroughClipcheck
  class ClipError < StandardError; end

  BOXES = 'boxes.json'
  TOKENS_FILE = 'video-tokens.json'
  OUTPUT_H = 1080.0

  module_function

  # The checkout's reference dir, then the installed skill's (scripts run
  # from ~/.claude/cf/bin, apart from the skills tree), as for compose
  # templates (WalkthroughCompose.template_roots).
  def token_roots
    [ File.expand_path('../skills/walkthrough/reference', __dir__),
      File.join(Dir.home, '.claude', 'skills', 'cf:walkthrough', 'reference'),
      File.join(Dir.home, '.config', 'opencode', 'skills', 'cf-walkthrough', 'reference') ]
  end

  def tokens_path(roots = token_roots)
    roots.map { |r| File.join(r, TOKENS_FILE) }.find { |f| File.file?(f) } or
      raise ArgumentError, "#{TOKENS_FILE} not found in #{roots.join(', ')}"
  end

  def tokens = @tokens ||= JSON.parse(File.read(tokens_path)).freeze

  def inset = tokens.dig('safe_area', 'inset')

  def label_min = tokens.dig('type_scale', 'label')

  # Checks one scene's boxes data. Returns { refusals:, warnings: }.
  def check(label, data)
    vp = data.fetch('viewport')
    w = vp['w'].to_f
    h = vp['h'].to_f
    safe = { x0: w * inset, y0: h * inset, x1: w * (1 - inset), y1: h * (1 - inset) }
    scale = OUTPUT_H / h
    seen = {}
    refusals = []
    fullest = 0.0
    Array(data['frames']).each do |f|
      boxes = Array(f['boxes'])
      fullest = [ fullest, fill(boxes, w, h) ].max
      boxes.each do |b|
        reason = reason_for(b, w, h, safe, scale)
        next unless reason && !seen.key?([ b['id'], reason[0] ])

        seen[[ b['id'], reason[0] ]] = true
        refusals << "#{label} at #{f['t_ms']} ms (frame #{f['frame']}): #{b['kind']} #{b['id'].inspect} #{reason[1]}"
      end
    end
    { refusals: refusals, warnings: fill_warnings(label, fullest) }
  end

  def reason_for(box, w, h, safe, scale)
    x0 = box['x'].to_f
    y0 = box['y'].to_f
    x1 = x0 + box['w'].to_f
    y1 = y0 + box['h'].to_f
    return [ :edge, 'crosses the frame edge' ] if x0.negative? || y0.negative? || x1 > w || y1 > h
    return [ :safe, "crosses the safe area (#{(inset * 100).round} percent inset)" ] if x0 < safe[:x0] || y0 < safe[:y0] || x1 > safe[:x1] || y1 > safe[:y1]
    return [ :overflow, 'overflows its box (text cut or ellipsized)' ] if box['overflow']

    size_reason(box, scale)
  end

  def size_reason(box, scale)
    return nil unless box['kind'] == 'text' && box['font_px'].is_a?(Numeric)

    px = box['font_px'] * scale
    return nil if px >= label_min

    [ :size, "renders #{px.round(1)} px, below the #{label_min} px label minimum; " \
             "split #{box['text'].to_s.inspect} into another scene rather than shrink it" ]
  end

  def fill(boxes, w, h)
    return 0.0 if boxes.empty?

    x0 = boxes.map { |b| b['x'].to_f }.min.clamp(0, w)
    y0 = boxes.map { |b| b['y'].to_f }.min.clamp(0, h)
    x1 = boxes.map { |b| b['x'].to_f + b['w'].to_f }.max.clamp(0, w)
    y1 = boxes.map { |b| b['y'].to_f + b['h'].to_f }.max.clamp(0, h)
    [ x1 - x0, 0 ].max * [ y1 - y0, 0 ].max / (w * h)
  end

  def fill_warnings(label, fullest)
    lo = tokens.dig('fill', 'min')
    hi = tokens.dig('fill', 'max')
    pct = (fullest * 100).round
    return [ "#{label}: fill #{pct} percent at its fullest frame is below #{(lo * 100).round} percent" ] if fullest < lo
    return [ "#{label}: fill #{pct} percent at its fullest frame is above #{(hi * 100).round} percent" ] if fullest > hi

    []
  end

  # The one-line verdict for a run over [[scene_id, result]]: PASS, or N
  # refusals across M scenes, so a clean run is never silent.
  def summary(results)
    hit = results.reject { |_, r| r[:refusals].empty? }
    PrototypeUxLint.verdict(scenes: results.size, findings: hit.sum { |_, r| r[:refusals].size }, hit: hit.size)
  end

  # Checks a scene's frames directory; nil when it has no boxes.json (a
  # screen kind that records none, or a cache from before the check).
  def check_dir(dir, label = File.basename(dir))
    path = File.join(dir, BOXES)
    return nil unless File.file?(path)

    check(label, JSON.parse(File.read(path)))
  end
end

if $PROGRAM_NAME == __FILE__
  abort('usage: walkthrough_clipcheck.rb <scene-frames-dir>...') if ARGV.empty?
  results = ARGV.filter_map do |dir|
    result = WalkthroughClipcheck.check_dir(dir)
    next puts("#{File.basename(dir)}: no #{WalkthroughClipcheck::BOXES}, skipped") unless result

    result[:warnings].each { |w| puts "warning: #{w}" }
    result[:refusals].each { |r| puts "refused: #{r}" }
    [ File.basename(dir), result ]
  end
  puts "clip check: #{WalkthroughClipcheck.summary(results)}"
  exit(results.any? { |_, r| r[:refusals].any? } ? 1 : 0)
end
