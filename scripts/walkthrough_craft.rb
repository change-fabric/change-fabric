# frozen_string_literal: true

require 'digest'
require 'json'

# The craft gate on a production walkthrough's final master. A free draft is
# exempt; only <slug>-final.mp4 is the master, and it is approved only when:
#
# - a completed craft roast round (cf:roast --video, which records the craft
#   rubric version and the SHA-256 of the MP4 it watched in round-N.video.json)
#   reviewed exactly this master's bytes; a master changed after its roast is
#   stale and refused; and
# - every craft P0 or P1 in the newest such round is covered by a human
#   override in round-N.video.response.json:
#     { "override": { "by": "name", "reason": "why", "master_sha256": "<sha>" } }
#   bound to the same hash. An override for another artifact is refused.
#
# The gate never spends: it reads the roast dir and hashes the file.
module WalkthroughCraft
  BLOCKING = %w[P0 P1].freeze
  DIR = 'roast'
  BRIEF = 'craft-brief.md'

  module_function

  def sha256(path) = Digest::SHA256.file(path).hexdigest

  # Video rounds that recorded a craft binding, oldest first:
  # [{ round:, sha:, critic:, response: }].
  def rounds(dir)
    Dir.glob(File.join(dir.to_s, 'round-*.video.json')).filter_map do |path|
      n = File.basename(path)[/\Around-(\d+)\.video\.json\z/, 1] or next
      critic = read_json(path) or next
      sha = critic.dig('craft', 'master_sha256') or next
      { round: n.to_i, sha: sha, critic: critic, response: read_json(File.join(dir, "round-#{n}.video.response.json")) }
    end.sort_by { |r| r[:round] }
  end

  def read_json(path)
    File.file?(path) ? JSON.parse(File.read(path)) : nil
  rescue JSON::ParserError
    nil
  end

  def blockers(critic) = Array(critic['issues']).select { |i| BLOCKING.include?(i['priority']) }

  # The override record when it is complete and bound to `sha`, else nil.
  def override_for(response, sha)
    o = response.is_a?(Hash) ? response['override'] : nil
    return nil unless o.is_a?(Hash) && o['master_sha256'] == sha
    return nil if o['by'].to_s.strip.empty? || o['reason'].to_s.strip.empty?

    o
  end

  # { approved:, reason:, round:, blockers: } for `master` under `dir`.
  def verdict(dir, master)
    return refuse("no final master at #{master}") unless master && File.file?(master)

    sha = sha256(master)
    all = rounds(dir)
    return refuse("no craft roast round on record for #{File.basename(master)} (#{short(sha)})") if all.empty?

    round = all.reverse.find { |r| r[:sha] == sha }
    unless round
      last = all.last
      return refuse("stale: #{File.basename(master)} (#{short(sha)}) changed after craft round #{last[:round]} " \
                    "reviewed #{short(last[:sha])}; roast the current master")
    end
    judge(round, sha)
  end

  def judge(round, sha)
    open = blockers(round[:critic])
    n = round[:round]
    return { approved: true, reason: "craft round #{n} reviewed this master (#{short(sha)}) with no P0/P1", round: n, blockers: [] } if open.empty?

    override = override_for(round[:response], sha)
    if override
      return { approved: true, round: n, blockers: open,
               reason: "#{open.size} craft P0/P1 in round #{n} overridden by #{override['by']}: #{override['reason']}" }
    end

    other = round[:response].is_a?(Hash) && round[:response]['override'].is_a?(Hash)
    why = other ? 'its override is bound to another artifact or incomplete' : 'no override recorded'
    { approved: false, round: n, blockers: open,
      reason: "#{open.size} open craft P0/P1 in round #{n} (#{why}); fix and re-render, or record " \
              "override {by, reason, master_sha256: #{sha}} in round-#{n}.video.response.json" }
  end

  def refuse(reason) = { approved: false, reason: reason, round: nil, blockers: [] }

  def short(sha) = sha.to_s[0, 12]

  # The paid step to take next, always as an estimate first.
  def roast_command(master, dir)
    "ruby scripts/roast.rb --video #{master} --brief #{File.join(dir, BRIEF)} --out-dir #{dir} --estimate-only"
  end

  # The final master beside a walkthrough dir: <slug>-final.mp4.
  def master_in(root) = Dir.glob(File.join(root, '*-final.mp4')).reject { |f| f.end_with?('.pr.mp4') }.max_by { |f| File.mtime(f) }
end

if __FILE__ == $PROGRAM_NAME
  root = ARGV.first or abort('usage: walkthrough_craft.rb walkthrough/<slug> [--master MP4]')
  master = ARGV.include?('--master') ? ARGV[ARGV.index('--master') + 1] : WalkthroughCraft.master_in(root)
  v = WalkthroughCraft.verdict(File.join(root, WalkthroughCraft::DIR), master)
  puts "craft gate: #{v[:approved] ? 'approved' : 'not approved'}: #{v[:reason]}"
  exit(v[:approved] ? 0 : 1)
end
