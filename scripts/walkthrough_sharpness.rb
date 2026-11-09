# frozen_string_literal: true

# Capture sizing for crisp frames. Every scene is composed on a stage: the
# board canvas, or the canvas times the camera zoom (or the hero push-in)
# when the scene is magnified before its final crop. Frames are captured
# with enough device pixels to fill their slot on that stage, so assembly
# only ever scales down, never up.
#
# The guard (`report`, `upscaled`) compares, per scene and device, the
# captured pixel width against the stage slot it is drawn into; a ratio
# above MAX_UPSCALE means text is resampled up and reads soft.
module WalkthroughSharpness
  # Slack for rounding (even sizes, bezels) before a stretch counts.
  MAX_UPSCALE = 1.05
  # The hero still's zoompan end zoom (WalkthroughFfmpeg.hero_filter).
  HERO_ZOOM = 1.12
  DPR = (1..4)

  module_function

  def viewport(board) = { 'w' => 1920, 'h' => 1080 }.merge(board['viewport'] || {})

  def camera_zoom(scene) = scene.dig('camera', 'zoom').to_f

  # How much larger than the canvas the scene is composed before its final
  # crop: the camera zoom when it magnifies, else the hero push-in.
  def stage_scale(scene)
    zoom = camera_zoom(scene)
    return zoom if zoom > 1
    return HERO_ZOOM if scene['hero_still'] == true

    1.0
  end

  def even(value) = 2 * (value / 2.0).floor

  # The stage in px: the same even rounding as the camera crop.
  def stage_size(board, scene)
    vp = viewport(board)
    s = stage_scale(scene)
    s == 1.0 ? [ vp['w'], vp['h'] ] : [ even(vp['w'] * s), even(vp['h'] * s) ]
  end

  # The board as seen by the stage compositors: the viewport resized to the
  # stage, so device and browser-frame layouts land at stage px.
  def stage_board(board, scene)
    w, h = stage_size(board, scene)
    board.merge('viewport' => viewport(board).merge('w' => w, 'h' => h))
  end

  # The device rects (name, w, h in stage px) a scene's frames fill.
  def slots(board, scene)
    require_relative 'walkthrough_device'
    staged = stage_board(board, scene)
    return WalkthroughBrowserFrame.layout(staged).rects if WalkthroughBrowserFrame.browser?(scene)

    WalkthroughDevice.layout(staged, scene).rects
  end

  # Device px per CSS px that fills a slot `slot_w` stage px wide from a
  # `css_w` viewport without stretching past MAX_UPSCALE.
  def needed_dpr(slot_w, css_w) = (slot_w.to_f / css_w / MAX_UPSCALE).ceil.clamp(DPR.min, DPR.max)

  # The desktop capture dpr: the storyboard's own viewport dpr wins,
  # otherwise derived from the desktop slot on the stage.
  def desktop_dpr(board, scene)
    explicit = board.dig('viewport', 'dpr')
    return explicit if explicit

    slot_dpr(board, scene, 'desktop', viewport(board)['w'])
  end

  # The phone capture dpr: its spec's dpr (2 by default), raised when the
  # phone's slot on the stage needs more.
  def phone_dpr(board, scene, phone) = [ phone['dpr'], slot_dpr(board, scene, 'phone', phone['w']) ].max

  def slot_dpr(board, scene, name, css_w)
    slot = slots(board, scene).find { |r| r.name == name }
    slot ? needed_dpr(slot.w, css_w) : 1
  end

  # Per device: captured px, slot px, and the stretch between them. A b-roll
  # clip is generated footage, not UI, and is not reported.
  def report(board, scene)
    require_relative 'walkthrough_storyboard'
    return [] if WalkthroughStoryboard.broll?(scene)

    specs = capture_specs(board, scene)
    slots(board, scene).filter_map do |slot|
      spec = specs.find { |s| s['name'] == slot.name } or next
      src_w = (spec['w'] * spec['dpr']).round
      src_h = (spec['h'] * spec['dpr']).round
      { 'scene' => scene['id'], 'device' => slot.name, 'captured' => [ src_w, src_h ], 'slot' => [ slot.w, slot.h ],
        'stretch' => (slot.w.to_f / src_w).round(3) }
    end
  end

  def capture_specs(board, scene)
    return WalkthroughDevice.specs(board, scene) if WalkthroughLive.realtime?(scene)

    [ PrototypeCapture.scene_viewport(board, scene).merge('name' => 'desktop') ]
  end

  # Report rows stretched past MAX_UPSCALE, across the board.
  def upscaled(board)
    WalkthroughStoryboard.scenes(board).flat_map { |s| report(board, s) }.select { |r| r['stretch'] > MAX_UPSCALE }
  end

  def describe(row)
    format('%<scene>s (%<device>s): captured %<cw>dx%<ch>d drawn into %<sw>dx%<sh>d, upscaled %<x>.2fx',
           scene: row['scene'], device: row['device'], cw: row['captured'][0], ch: row['captured'][1],
           sw: row['slot'][0], sh: row['slot'][1], x: row['stretch'])
  end
end
