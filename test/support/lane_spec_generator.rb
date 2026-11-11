# frozen_string_literal: true

require_relative "../../scripts/diagram_text_fit"
require_relative "../../scripts/walkthrough_diagram"

# Seeded swimlane diagram specs for the generated capture test. One seed
# always gives the same spec. Each draws from every axis the lane layer
# branches on: lane direction, label length (one character, typical, exactly
# at its budget, CJK at its budget), report on or off, laned and unlaned
# nodes, icons on or off, zero or more travels (tokens and markers), and an
# authored highlight on a random checkpoint, with
# travels spaced one or two beats apart. Every spec it returns passes
# WalkthroughDiagram.spec_errors; a spec that does not is a generator bug.
class LaneSpecGenerator
  WORDS = %w[load budget scan audit check sweep cases viewport contrast alert report widths clean review merge
             deploy release smoke tests static gate build lint policy owner].freeze
  CJK = %w[検 査 負 荷 監 視 安 全 確 認 試 験].freeze
  ICONS = %w[gauge lock wheelchair shield-check devices test-tube rocket gear].freeze
  LENGTHS = %i[one typical max cjk].freeze
  DURATION_MS = 8000
  STEP_GAP = 1400
  TRAVEL_MS = 700

  attr_reader :seed

  def initialize(seed)
    @seed = seed
    @rng = Random.new(seed)
  end

  def spec
    @spec ||= build.tap do |d|
      errs = WalkthroughDiagram.spec_errors(d, DURATION_MS)
      raise "seed=#{seed}: generator emitted an invalid spec: #{errs.join('; ')}" unless errs.empty?
    end
  end

  # The checkpoint an authored highlight names, or nil.
  def highlighted = spec["steps"].find { |s| s["op"] == "highlight" }&.dig("id")

  private

  def pick(list) = list[@rng.rand(list.size)]

  def chance(p) = @rng.rand < p

  def build
    horizontal = chance(0.6)
    lanes = Array.new(@rng.rand(1..4)) { |i| lane(i) }
    travels = chance(0.8) ? lanes.select { chance(0.8) } : []
    travels = [ lanes.first ] if travels.empty? && chance(0.5)
    report = horizontal && !travels.empty? && chance(0.6)
    token = travels.any? && chance(0.8) ? token_node : nil
    results = travels.select { chance(0.7) }.to_h { |l| [ l["id"], result_node(l, report) ] }
    room = WalkthroughDiagram::MAX_NODES - results.size - (token ? 1 : 0)
    checks = checkpoints(lanes, horizontal, room)
    free = Array.new([ room - checks.size, @rng.rand(0..2) ].min) { |k| { "id" => "n-#{k}", "label" => typical(2) } }
    place_results(results.values, checks, horizontal) unless report
    nodes = checks + free + [ token ].compact + results.values
    steps = travel_steps(travels, token, results)
    hl = checks.select { |c| c["lane"] }.then { |cs| cs.empty? || !chance(0.7) ? nil : pick(cs) }
    steps.unshift({ "t_ms" => 100, "op" => "highlight", "id" => hl["id"] }) if hl
    steps.unshift({ "t_ms" => 0, "op" => "fit_view", "padding" => 0.06 })
    d = { "layout" => { "engine" => chance(0.5) ? "manual" : "dagre" }, "theme" => chance(0.5) ? "dark" : "light",
          "lanes" => lanes, "nodes" => nodes, "edges" => edges(checks + free),
          "initial" => (checks + free).map { |n| n["id"] }, "steps" => steps }
    d["lane_direction"] = "vertical" unless horizontal
    d["report"] = { "label" => pick([ "Report", "Results", "検査結果" ]) } if report
    d
  end

  def lane(i)
    l = { "id" => "l#{i}" }
    l["icon"] = pick(ICONS) if chance(0.5)
    room = DiagramTextFit.room("lane_label", icon: l["icon"])
    l["label"] = label(pick(LENGTHS), DiagramTextFit::FIT["lane_label"]["font"], room)
    l
  end

  def token_node
    n = { "id" => "tok" }
    n["icon"] = "git-pull-request" if chance(0.5)
    n["label"] = label(pick(LENGTHS), DiagramTextFit::FIT["token"]["font"], DiagramTextFit.room("token", icon: n["icon"]))
    n
  end

  # Without a report a result is a standalone card the size of a node, so
  # its label stays short; with one it fills its row beside its lane name.
  def result_node(lane, report)
    f = DiagramTextFit::FIT["report_row"]
    room = f["width"] - DiagramTextFit.width(lane["label"], f["aside_font"])
    { "id" => "r-#{lane['id']}", "label" => report ? label(pick(LENGTHS), f["font"], room) : typical(2) }
  end

  # One or two checkpoints a lane, pinned along the lane at a stride wide
  # enough for any card, within the node cap.
  def checkpoints(lanes, horizontal, room)
    fc = DiagramTextFit::FIT["checkpoint"]
    lanes.flat_map do |l|
      Array.new(@rng.rand(1..2)) do |k|
        n = { "id" => "c-#{l['id']}-#{k}", "lane" => l["id"] }
        n["icon"] = pick(ICONS) if chance(0.3)
        n["label"] = horizontal ? wrapped(pick(LENGTHS), fc, DiagramTextFit.room("checkpoint", icon: n["icon"])) : typical(2)
        n["position"] = horizontal ? { "x" => k * 300, "y" => 0 } : { "x" => 0, "y" => k * 160 }
        n
      end
    end.first(room)
  end

  def place_results(results, checks, horizontal)
    far = (checks.map { |c| horizontal ? c["position"]["x"] : c["position"]["y"] }.max || 0) + 700
    results.each_with_index do |r, i|
      r["position"] = horizontal ? { "x" => far, "y" => i * 90 } : { "x" => i * 300, "y" => far }
    end
  end

  # Travels start STEP_GAP apart, or sometimes twice that, so a later
  # travel can start after an earlier result has long landed.
  def travel_steps(lanes, token, results)
    at = 300 - STEP_GAP
    lanes.map do |l|
      at += at + (2 * STEP_GAP) <= 5800 && chance(0.4) ? 2 * STEP_GAP : STEP_GAP
      s = { "t_ms" => at, "op" => "travel", "lane" => l["id"], "duration" => TRAVEL_MS }
      s["id"] = token["id"] if token
      s["result"] = results[l["id"]]["id"] if results[l["id"]]
      s
    end
  end

  def edges(nodes)
    return [] if nodes.size < 2 || !chance(0.5)

    nodes.each_cons(2).first(3).each_with_index.map { |(a, b), i| { "id" => "e-#{i}", "source" => a["id"], "target" => b["id"] } }
  end

  def typical(words) = Array.new(words) { pick(WORDS) }.join(" ").capitalize

  # A one-line label of the given length class that fits `room` px.
  def label(kind, font, room)
    case kind
    when :one then pick(WORDS)[0].upcase
    when :typical then fill(typical(3).split, font, room, " ")
    when :max then fill(Array.new(40) { pick(WORDS) }.join(" ").capitalize.split, font, room, " ")
    else fill(Array.new(40) { pick(CJK) }, font, room, "")
    end
  end

  # Joins `parts` while the text still fits one line of `room` px.
  def fill(parts, font, room, sep)
    parts.reduce(nil) do |text, part|
      trial = text ? "#{text}#{sep}#{part}" : part
      break text if DiagramTextFit.width(trial, font) > room

      trial
    end || parts.first[0]
  end

  # A checkpoint label of the given length class within its line cap.
  def wrapped(kind, fit, room)
    return label(kind, fit["font"], room) if %i[one typical].include?(kind)

    parts = kind == :cjk ? Array.new(40) { pick(CJK) } : Array.new(40) { pick(WORDS) }
    sep = kind == :cjk ? "" : " "
    parts.reduce(nil) do |text, part|
      trial = text ? "#{text}#{sep}#{part}" : part
      break text if DiagramTextFit.lines(trial, fit["font"], room).size > fit["lines"]

      trial
    end
  end
end
