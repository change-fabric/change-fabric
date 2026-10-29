# frozen_string_literal: true

require 'fileutils'
require_relative 'roast'

# The cf:roast gate on every walkthrough draft: which frames of the rendered
# draft go to the critic, the walkthrough rubric it reads them against, and
# the --final refusal while the latest draft roast has an open P0 or P1. The
# render script only gates and reports; accepting, rebutting, and fixing stay
# with the session, as cf:roast describes.
module WalkthroughRoast
  DEFAULT_CEILING_USD = 0.5
  DIR = 'roast'

  class OpenFindingsError < StandardError; end

  RUBRIC = <<~TEXT
    These are keyframes of a narrated product walkthrough video at 1920x1080: each scene's start,
    middle, and end, plus the frame where a toast or sheet first appears. The cursor and captions are
    composited in. Judge the frames as a viewer of the finished video. Name each issue's screen as
    the keyframe file name. Check, in order:
    1. Blank or unlabeled controls: a button, toast, status bar, or sheet that shows only an icon or nothing.
    2. Overlays hiding controls: a toast, sheet, or banner covering a button, field, or the navigation,
       or a covered label bleeding through.
    3. Cursor or label collisions: the cursor sprite covering a button's label text.
    4. State contradictions: a success badge or toast while the actions it reports are still live, or
       a confirmation shown before the action was taken.
    5. Caption or safe-area collisions: captions over UI the narration points at, content in the outer 5% of the frame,
       or any control or device frame reaching into the bottom 15% of the frame, where players draw captions.
    6. Device frame consistency: a phone or device frame that changes aspect ratio, bezel, or layout width
       between scenes, or changes size other than by a smooth camera zoom.
    7. Clipped content: text or a control cut off by its container or by the device edge.
    8. Readability at 1080p: text too small, too low in contrast, or too brief on screen to read.
    9. Fractal and usability consistency: one module set repeated at every scale (cf:fractal), and
       Nielsen's ten heuristics (cf:usability), especially visibility of system status and consistency.
    10. Simulated notifications and messages: a lock screen banner, thread, inbox, or email that is hard to read,
       implausible for the moment, inconsistent with the app's look, or that does not lead visibly into the
       app screen its tap opens.
  TEXT

  module_function

  # Keyframes as [{ scene:, label:, frame: (0-based, whole video) }], in
  # video order. `overlays` maps scene id to { overlay => first local frame }.
  def keyframes(entries, overlays = {})
    entries.flat_map do |e|
      n = e['frames'].to_i
      local = { 'start' => 0, 'middle' => n / 2, 'end' => n - 1 }
      (overlays[e['id']] || {}).each { |key, f| local[overlay_label(key)] ||= f.to_i }
      local.select { |_, f| f.between?(0, n - 1) }.map { |label, f| { scene: e['id'], label: label, frame: e['start_frame'].to_i + f } }
    end.uniq { |k| k[:frame] }.sort_by { |k| k[:frame] }
  end

  def overlay_label(key) = "overlay-#{key.gsub(/[^a-z0-9]+/i, '-').delete_prefix('-')}"

  def keyframe_name(index, key) = format('%03d-%s-%s.jpg', index + 1, key[:scene], key[:label])

  # FFmpeg args that write each keyframe of `mp4` as a numbered JPEG.
  def extract_args(mp4, keys, out_pattern)
    select = keys.map { |k| "eq(n\\,#{k[:frame]})" }.join('+')
    [ '-hide_banner', '-y', '-i', mp4, '-vf', "select=#{select}", '-fps_mode', 'passthrough', '-q:v', '3', out_pattern ]
  end

  def brief(board)
    goal = board['title'] || board['slug'] || 'the walkthrough'
    "Walkthrough: #{goal}.\n\n#{RUBRIC}"
  end

  # The latest round's P0 and P1 issues not rebutted in its response file.
  def open_blockers(history)
    return [] unless (last = history.last)

    responses = Array(last.dig(:response, 'responses'))
    last[:critic]['issues'].reject.with_index do |issue, i|
      !Roast::BLOCKING.include?(issue['priority']) || rebutted?(issue, responses, i)
    end
  end

  def rebuttal_for?(issue, response) = response && response['verdict'] == 'rebut' && response['screen'] == issue['screen']

  def rebutted?(issue, responses, index)
    rebuttal_for?(issue, responses[index]) ||
      responses.any? { |r| rebuttal_for?(issue, r) && issue['problem'].to_s.include?(r['problem'].to_s.strip) }
  end
  private_class_method :rebuttal_for?, :rebutted?

  # Raises when the latest draft roast in `dir` has an open P0 or P1.
  def gate!(dir, allow: false)
    open = open_blockers(Roast.load_history(dir))
    return if open.empty? || allow

    lines = open.map { |i| "#{i['priority']} (#{i['screen']}): #{i['problem']}" }
    raise OpenFindingsError, "#{open.size} open P0/P1 roast finding(s) block --final (pass --allow-roast-findings to override):\n" \
                             "#{lines.join("\n")}"
  end
end
