# frozen_string_literal: true

require 'fileutils'
require_relative 'design_config'
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
  # The fidelity loop's own log (spec 0.18.0 design targets with a
  # reference): roast/fidelity/ beside the draft roast, with its own rounds,
  # open blockers, and stop verdict.
  FIDELITY_DIR = File.join(DIR, 'fidelity')
  FIDELITY_TARGET = 9.0
  SIGNOFF = 'signoff.json'
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

  # The loop's settings for one run: each flag given wins, else
  # change_config.design.roast in the repo's CHANGE.md, else the defaults above.
  # `flags` keys: :roast (false is --no-roast), :max_usd, :target, :rounds,
  # :model. auto: false in the config reads as --no-roast. A malformed design
  # block raises DesignConfig::Error naming the field.
  def settings(repo_root, flags = {})
    cfg = DesignConfig.load(repo_root).default.roast
    given = flags.compact
    { roast: given.fetch(:roast, cfg.auto != false),
      max_usd: given.fetch(:max_usd, cfg.max_usd || DEFAULT_CEILING_USD).to_f,
      target: given.fetch(:target, cfg.target || TARGET).to_f,
      rounds: given.fetch(:rounds, cfg.rounds || ROUND_CAP).to_i,
      model: Roast.model_for(kind: cfg.kind, flag: given[:model], config: cfg.model),
      review: { kind: cfg.kind, audience: cfg.audience }.compact }
  end

  # The review contract for one roast round: the storyboard's review object over
  # the CHANGE.md defaults in `config` ({ kind:, audience: }). Raises
  # Roast::ReviewError (a RequestError) when audience or purpose is missing.
  # A board that films a running app (any live scene) defaults to the film
  # scope, so the critic grades camera work rather than the shipped product UI.
  def review(board, config = {})
    defaults = live?(board) ? config.merge(scope: 'film') : config
    Roast.resolve_review(storyboard: board['review'], config: defaults)
  end

  def live?(board) = WalkthroughStoryboard.scenes(board).any? { |s| s['screen'].is_a?(Hash) && s['screen'].key?('url') }

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

    responses = response_entries(last[:response])
    Roast.normalize_issues(last[:critic]['issues'], last[:round]).reject.with_index do |issue, i|
      !Roast::BLOCKING.include?(issue['priority']) || rebutted?(issue, responses, i)
    end
  end

  REBUT_VERDICTS = %w[rebut rebutted].freeze

  # The response entries, from { "responses": [...] } or a bare list.
  def response_entries(response)
    list = response.is_a?(Hash) ? response['responses'] : response
    Array(list).select { |r| r.is_a?(Hash) }
  end

  def rebut?(response) = REBUT_VERDICTS.include?((response['verdict'] || response['decision']).to_s.strip.downcase)

  # A response carrying an id answers only the issue with that id. One without
  # (older files) names the issue by location plus its problem or summary text,
  # or, with neither, the issue at its own position.
  def rebutted?(issue, responses, index)
    responses.each_with_index.any? do |r, i|
      next r['id'] == issue['id'] && rebut?(r) if r['id']
      next false unless rebut?(r) && Roast.location(r) == Roast.location(issue)

      named = (r['problem'] || r['summary']).to_s.strip
      problem = issue['problem'].to_s
      named.empty? ? i == index : problem.include?(named) || named.include?(problem.strip)
    end
  end
  private_class_method :rebutted?

  # -- run spend ledger ---------------------------------------------------

  # An unreadable ledger fails closed: the cap reads as reached, never as zero spend.
  def ledger(dir)
    path = File.join(dir, LEDGER)
    data = File.file?(path) ? JSON.parse(File.read(path)) : {}
    raise JSON::ParserError, 'ledger is not an object' unless data.is_a?(Hash) && (data['rounds'] || {}).is_a?(Hash)

    content = data['content'].is_a?(Hash) ? data['content'] : {}
    scenes = data['scenes'].is_a?(Hash) ? { 'scenes' => data['scenes'] } : {}
    { 'rounds' => data['rounds'] || {}, 'capped' => data['capped'] == true, 'content' => content, **scenes }
  rescue JSON::ParserError
    { 'rounds' => {}, 'capped' => true, 'unreadable' => true, 'content' => {} }
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

  # The content key of what a round reviewed, so a later edit voids its pass.
  def record_content(dir, round, key)
    write_ledger(dir, ledger(dir).tap { |l| l['content'][round.to_s] = key })
  end

  # -- scope ---------------------------------------------------------------

  # Where a superseded loop's rounds and ledger move when the film changes.
  SUPERSEDED = 'superseded'

  # The scene keys ({ id => digest }) the loop is scoped to: recorded on the
  # first round of a scope, kept until the film changes materially.
  def record_scenes(dir, scenes)
    return if scenes.nil? || ledger(dir).key?('scenes')

    write_ledger(dir, ledger(dir).merge('scenes' => scenes))
  end

  # A material change: a scene added, dropped or renamed, or at least half
  # of the scenes re-keyed. A fix to one scene of several is not one.
  def material_change?(was, now)
    return true unless was.keys.sort == now.keys.sort

    changed = now.count { |id, key| was[id] != key }
    changed.positive? && changed * 2 >= now.size
  end

  # Starts a fresh loop when the film changed materially since the loop's
  # scope was recorded: the rounds, keyframes and ledger move to superseded/N/, so the
  # round count, spend, and verdict restart. Returns the archive dir or nil.
  #
  # A ledger from before scene tracking has no baseline. Its loop restarts
  # once if the content changed since its last round (it cannot tell a fix
  # from a rework); otherwise the current scenes become its baseline.
  def rescope!(dir, scenes, content: nil)
    # An unreadable ledger stays fail-closed: its spend is unknown.
    return nil unless scenes && !unreadable?(dir)

    was = ledger(dir)['scenes']
    if was.nil?
      last = Roast.load_history(dir).last
      return nil unless last

      unless content && ledger(dir)['content'][last[:round].to_s] != content
        write_ledger(dir, ledger(dir).merge('scenes' => scenes))
        return nil
      end
    elsif !material_change?(was, scenes)
      return nil
    end

    archive = File.join(dir, SUPERSEDED, (Dir.glob(File.join(dir, SUPERSEDED, '*')).size + 1).to_s)
    FileUtils.mkdir_p(archive)
    Dir.glob(File.join(dir, 'round-*')).push(File.join(dir, LEDGER), File.join(dir, 'keyframes')).each { |f| FileUtils.mv(f, archive) if File.exist?(f) }
    archive
  end

  # A round skipped because it would pass the run cap: the loop is over.
  def mark_capped(dir) = write_ledger(dir, ledger(dir).merge('capped' => true))

  # The loop's stop rule over the latest round. Unlike Roast.decide (any one of
  # target, no blockers, or cap stops), converging here needs the 8.5 target AND
  # no open P0/P1, so the blocker check comes first and a cap stop is never a pass.
  # With `content`, a pass counts only for the content the last round reviewed:
  # an edit or recapture since then reopens the loop; the caps still stop it.
  def decide(dir, cap_usd: DEFAULT_CEILING_USD, target: TARGET, rounds: ROUND_CAP, content: nil)
    last = Roast.load_history(dir).last
    return { stop: false, converged: false, reason: 'no roast round yet' } unless last

    score = last[:critic]['score']
    blockers = open_blockers([ last ])
    state = "score #{score}, #{blockers.size} open P0/P1"
    total = spent(dir)
    cost = format('$%.2f of $%.2f', total, cap_usd)
    passed = score >= target && blockers.empty?
    if passed && content && ledger(dir)['content'][last[:round].to_s] != content
      passed = false
      state = "#{state}, content changed since round #{last[:round]} was reviewed"
    end
    if passed
      { stop: true, converged: true, reason: "#{state}, target #{target} reached" }
    elsif last[:round] >= rounds
      { stop: true, converged: false, reason: "round cap #{rounds} reached, #{state}" }
    elsif unreadable?(dir)
      { stop: true, converged: false, reason: "spend ledger unreadable, treated as cap reached, #{state}" }
    elsif capped?(dir) || total >= cap_usd - 1e-9
      { stop: true, converged: false, reason: "spend cap reached (#{cost}), #{state}" }
    else
      { stop: false, converged: false, reason: "#{state}, round #{last[:round]} of #{rounds}, #{cost} spent" }
    end
  end

  def raise_open_blockers(blockers, label: 'roast', flag: '--allow-roast-findings')
    lines = blockers.map { |i| "#{i['id'] || '(no id)'} #{i['severity'] || i['priority']} (#{Roast.location(i)}): #{Roast.summary_of(i['problem'])}" }
    raise OpenFindingsError, "#{blockers.size} unrebutted P0/P1 #{label} finding(s) block --final (rebut each in the round's " \
                             "response file, or pass #{flag} to override):\n" \
                             "#{lines.join("\n")}"
  end

  # -- fidelity loop ------------------------------------------------------

  # The fidelity loop's stop verdict over `dir` (roast/fidelity/): Roast.decide
  # with the 9 target as an advisory stop, round cap 4. A stop is the stills
  # sign-off and is recorded in signoff.json.
  def fidelity_verdict(dir, target: FIDELITY_TARGET, rounds: ROUND_CAP)
    history = Roast.load_history(dir)
    return { stop: false, reason: 'no fidelity round yet' } if history.empty?

    Roast.decide(history, target: target, cap: rounds)
  end

  def record_signoff(dir, verdict)
    return nil unless verdict[:stop]

    last = Roast.load_history(dir).last
    FileUtils.mkdir_p(dir)
    path = File.join(dir, SIGNOFF)
    File.write(path, "#{JSON.pretty_generate('round' => last && last[:round], 'score' => last && last[:critic]['score'],
                                              'reason' => verdict[:reason])}\n")
    path
  end

  # --final with a reference target blocks only on open fidelity P0/P1; the
  # score target is advisory. No fidelity round on record also blocks, since
  # an unrun comparison has no findings to clear.
  def fidelity_gate!(dir, allow: false)
    return if allow

    history = Roast.load_history(dir)
    if history.empty?
      raise OpenFindingsError, 'no fidelity roast on record for this reference target; compare the prototype stills with ' \
                               'the reference first (pass --allow-fidelity-findings to override)'
    end
    blockers = open_blockers(history)
    raise_open_blockers(blockers, label: 'fidelity', flag: '--allow-fidelity-findings') unless blockers.empty?
  end
  private_class_method :raise_open_blockers

  # Raises when --final has no finished roast loop behind it: no roast on
  # record (when one is required), an open P0 or P1 (also at a cap, which
  # reports them), or a loop that has neither converged nor hit a cap.
  def gate!(dir, allow: false, cap_usd: DEFAULT_CEILING_USD, require_roast: false, target: TARGET, rounds: ROUND_CAP, content: nil)
    return if allow

    history = Roast.load_history(dir)
    if history.empty?
      return unless require_roast

      raise OpenFindingsError, 'no draft roast on record; the roast loop runs on every draft before --final ' \
                               '(pass --allow-roast-findings to override)'
    end
    blockers = open_blockers(history)
    raise_open_blockers(blockers) unless blockers.empty?
    verdict = decide(dir, cap_usd: cap_usd, target: target, rounds: rounds, content: content)
    return if verdict[:stop]

    raise OpenFindingsError, "the roast loop is unfinished (#{verdict[:reason]}): apply the accepted fixes, render the next draft, " \
                             "and repeat until score >= #{target} with no P0/P1 or a cap (pass --allow-roast-findings to override)"
  end
end
