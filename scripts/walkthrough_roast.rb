# frozen_string_literal: true

require 'fileutils'
require_relative 'roast'
require_relative 'walkthrough_storyboard'

# The cf:roast gate on every walkthrough draft: which frames of the rendered
# draft go to the critic, the walkthrough rubric it reads them against, and
# the --final refusal while the latest draft roast has an open P0 or P1. The
# render script only gates and reports; accepting, rebutting, and fixing stay
# with the session, as cf:roast describes.
module WalkthroughRoast
  # The run-wide spend cap across every roast round of one walkthrough, not a
  # per-round ceiling.
  DEFAULT_CEILING_USD = 2.0
  DIR = 'roast'
  LEDGER = 'spend.json'
  TARGET = 8.5
  ROUND_CAP = Roast::DEFAULT_CAP

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
    The narration transcript with caption cues is given beside the frames. Also judge it, naming the
    scene id as the screen:
    11. Pacing: a scene whose words per minute (listed per scene) is rushed or draggy, or a long silence.
    12. Clarity and jargon: a sentence a first-time viewer cannot follow, or an unexplained term or acronym.
    13. Narration against screen: narration describing something not visible in that scene's keyframes,
       a visible key action the narration never mentions, or narration running ahead of or behind the action.
    14. Caption-band clash: a caption cue that would sit over UI the narration points at, or a cue too long
       to read in the time it is shown.
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

  # Narration and caption text with timing and per-scene words per minute, for
  # the critic to read beside the frames. `srt` is the rendered captions.srt.
  def transcript(board, manifest, srt = nil)
    fps = manifest.dig('timeline', 'fps').to_f
    by_id = WalkthroughStoryboard.scenes(board).to_h { |s| [ s['id'], s ] }
    lines = manifest['scenes'].filter_map { |e| transcript_line(e, by_id.dig(e['id'], 'narration', 'text').to_s.strip, fps) }
    out = [ 'Narration by scene:', *lines ]
    out += [ '', 'Caption cues:', srt.strip ] if srt && !srt.strip.empty?
    out.join("\n")
  end

  def transcript_line(entry, text, fps)
    return if text.empty?

    start = entry['start_frame'].to_i / fps
    secs = entry['frames'].to_i / fps
    wpm = secs.positive? ? (text.split.size * 60 / secs).round : 0
    format('%<id>s [%<s>.1fs to %<e>.1fs, %<wpm>d wpm]: %<t>s', id: entry['id'], s: start, e: start + secs, wpm: wpm, t: text)
  end
  private_class_method :transcript_line

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

  # -- run spend ledger ---------------------------------------------------

  # An unreadable ledger fails closed: the cap reads as reached, never as zero spend.
  def ledger(dir)
    path = File.join(dir, LEDGER)
    data = File.file?(path) ? JSON.parse(File.read(path)) : {}
    raise JSON::ParserError, 'ledger is not an object' unless data.is_a?(Hash) && (data['rounds'] || {}).is_a?(Hash)

    { 'rounds' => data['rounds'] || {}, 'capped' => data['capped'] == true }
  rescue JSON::ParserError
    { 'rounds' => {}, 'capped' => true, 'unreadable' => true }
  end

  def spent(dir) = ledger(dir)['rounds'].values.sum(&:to_f)

  def capped?(dir) = ledger(dir)['capped']

  def unreadable?(dir) = ledger(dir)['unreadable'] == true

  def write_ledger(dir, data)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, LEDGER), "#{JSON.pretty_generate(data)}\n")
  end

  def record_spend(dir, round, usd)
    write_ledger(dir, ledger(dir).tap { |l| l['rounds'][round.to_s] = usd.to_f.round(4) })
  end

  # A round skipped because it would pass the run cap: the loop is over.
  def mark_capped(dir) = write_ledger(dir, ledger(dir).merge('capped' => true))

  # The loop's stop rule over the latest round. Unlike Roast.decide (any one of
  # target, no blockers, or cap stops), converging here needs the 8.5 target AND
  # no open P0/P1, so the blocker check comes first and a cap stop is never a pass.
  def decide(dir, cap_usd: DEFAULT_CEILING_USD)
    last = Roast.load_history(dir).last
    return { stop: false, converged: false, reason: 'no roast round yet' } unless last

    score = last[:critic]['score']
    blockers = open_blockers([ last ])
    state = "score #{score}, #{blockers.size} open P0/P1"
    total = spent(dir)
    cost = format('$%.2f of $%.2f', total, cap_usd)
    if score >= TARGET && blockers.empty?
      { stop: true, converged: true, reason: "#{state}, target #{TARGET} reached" }
    elsif last[:round] >= ROUND_CAP
      { stop: true, converged: false, reason: "round cap #{ROUND_CAP} reached, #{state}" }
    elsif unreadable?(dir)
      { stop: true, converged: false, reason: "spend ledger unreadable, treated as cap reached, #{state}" }
    elsif capped?(dir) || total >= cap_usd - 1e-9
      { stop: true, converged: false, reason: "spend cap reached (#{cost}), #{state}" }
    else
      { stop: false, converged: false, reason: "#{state}, round #{last[:round]} of #{ROUND_CAP}, #{cost} spent" }
    end
  end

  def raise_open_blockers(blockers)
    lines = blockers.map { |i| "#{i['priority']} (#{i['screen']}): #{i['problem']}" }
    raise OpenFindingsError, "#{blockers.size} open P0/P1 roast finding(s) block --final (pass --allow-roast-findings to override):\n" \
                             "#{lines.join("\n")}"
  end
  private_class_method :raise_open_blockers

  # Raises when --final has no finished roast loop behind it: no roast on
  # record (when one is required), an open P0 or P1 (also at a cap, which
  # reports them), or a loop that has neither converged nor hit a cap.
  def gate!(dir, allow: false, cap_usd: DEFAULT_CEILING_USD, require_roast: false)
    return if allow

    history = Roast.load_history(dir)
    if history.empty?
      return unless require_roast

      raise OpenFindingsError, 'no draft roast on record; the roast loop runs on every draft before --final ' \
                               '(pass --allow-roast-findings to override)'
    end
    blockers = open_blockers(history)
    raise_open_blockers(blockers) unless blockers.empty?
    verdict = decide(dir, cap_usd: cap_usd)
    return if verdict[:stop]

    raise OpenFindingsError, "the roast loop is unfinished (#{verdict[:reason]}): apply the accepted fixes, render the next draft, " \
                             "and repeat until score >= #{TARGET} with no P0/P1 or a cap (pass --allow-roast-findings to override)"
  end
end
