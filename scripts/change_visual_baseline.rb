# frozen_string_literal: true

require 'base64'
require 'json'
require 'shellwords'
require_relative 'change_flow_compiler'
require_relative 'change_selector_suggestions'
require_relative 'change_testcases_evidence'

# Judges an `expect_visual` capture against the baseline PNG committed at
# `.cf/visual/<suite>/<case>/<name>-<width>x<height>.png`.
# `pass` and `fail` need a baseline and a diff. `blocked` means no verdict could
# be reached (no baseline, an unreadable or unsafe one, no diff container): the
# case still fails and nothing is ever accepted automatically. A missing
# baseline is never written; the candidate image is kept as evidence with a
# command a person can run to accept it.
#
# The pixel diff runs in the pinned browserless container (the `runner` is the
# lane's own session). A pixel differs when a channel is off by more than
# PIXEL_TOLERANCE; `max_diff_ratio` 0 allows none. Free text shown to a reader
# goes through the shared ChangeSelectorSuggestions.safe clip-and-redact.
module ChangeVisualBaseline
  DIR = %w[.cf visual].freeze
  PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
  MAX_BYTES = 12 * 1024 * 1024
  PIXEL_TOLERANCE = 2
  DIFF_TIMEOUT_MS = 120_000

  class Unsafe < StandardError; end

  # The in-container diff: counts, and a PNG of the differing pixels in red.
  DIFF_JS = <<~JS
    export default async ({ page }) => {
      const input = __INPUT__;
      const data = await page.evaluate(async (baseline, actual, tolerance) => {
        const load = async (b64) => {
          const bytes = Uint8Array.from(atob(b64), (char) => char.charCodeAt(0));
          const bitmap = await createImageBitmap(new Blob([bytes], { type: "image/png" }), { colorSpaceConversion: "none", premultiplyAlpha: "none" });
          const canvas = document.createElement("canvas");
          canvas.width = bitmap.width; canvas.height = bitmap.height;
          const ctx = canvas.getContext("2d", { willReadFrequently: true });
          ctx.drawImage(bitmap, 0, 0);
          return { width: bitmap.width, height: bitmap.height, ctx: ctx };
        };
        const a = await load(baseline);
        const b = await load(actual);
        if (a.width !== b.width || a.height !== b.height) return { sizeMismatch: true, baseline: [a.width, a.height], actual: [b.width, b.height] };
        const total = a.width * a.height;
        const left = a.ctx.getImageData(0, 0, a.width, a.height).data;
        const right = b.ctx.getImageData(0, 0, b.width, b.height).data;
        const out = new ImageData(a.width, a.height);
        let differing = 0;
        for (let i = 0; i < left.length; i += 4) {
          const gap = Math.max(...[0, 1, 2, 3].map((c) => Math.abs(left[i + c] - right[i + c])));
          if (gap > tolerance) differing += 1;
          out.data.set(gap > tolerance ? [255, 0, 0, 255] : [right[i], right[i + 1], right[i + 2], 60], i);
        }
        const canvas = document.createElement("canvas");
        canvas.width = a.width; canvas.height = a.height;
        canvas.getContext("2d").putImageData(out, 0, 0);
        return { total: total, differing: differing, diff: canvas.toDataURL("image/png").split(",")[1] };
      }, input.baseline, input.actual, input.tolerance);
      return { data: data, type: "application/json" };
    };
  JS

  module_function

  # The baseline's path under `root`, built from validated parts and refused
  # when any component of it is a symlink, so it never leaves the project.
  def path_for(root, suite:, case_id:, name:, viewport:)
    base = File.realpath(root)
    parts = [ *DIR, ChangeTestcasesEvidence.slug(suite), ChangeTestcasesEvidence.slug(case_id), "#{name}-#{viewport}.png" ]
    raise Unsafe, 'the baseline name is not a plain word' unless name.to_s.match?(ChangeFlowCompiler::VISUAL_NAME)

    walked = base
    parts.each do |part|
      walked = File.join(walked, part)
      raise Unsafe, "#{relative(base, walked)} is a symlink" if File.symlink?(walked)
    end
    walked
  end

  # The baseline's bytes, nil when there is none; Unsafe unless a plain, small file.
  def read(path)
    return nil unless File.exist?(path) || File.symlink?(path)

    raise Unsafe, 'the baseline is not a regular file' unless File.file?(path) && !File.symlink?(path)
    raise Unsafe, "the baseline is over #{MAX_BYTES / 1_048_576} MB" if File.size(path) > MAX_BYTES

    File.open(path, File::RDONLY | File::NOFOLLOW) { |file| file.read(MAX_BYTES + 1).b }
  rescue Errno::ELOOP
    raise Unsafe, 'the baseline is a symlink'
  end

  def png_size(bytes)
    return nil unless bytes.is_a?(String) && bytes.bytesize >= 24 && bytes.b[0, 8] == PNG_SIGNATURE && bytes.b[12, 4] == 'IHDR'

    bytes.b[16, 8].unpack('NN')
  end

  # Judges each expect_visual step of `record`, failing the step and the record
  # unless it passes. `runner` takes the diff JS and returns its data, or raises; `evidence_dir` receives the baseline and diff images.
  def judge(record, compiled:, root:, suite:, case_id:, evidence_dir: nil, secrets: [], runner: nil)
    steps = Array(record['steps']).select { |step| step.is_a?(Hash) && step['visual'].is_a?(Hash) }
    results = steps.map do |step|
      spec = compiled.find { |entry| entry[:index] == step['index'] }
      result = judge_step(step, spec, root, suite, case_id, evidence_dir, runner)
      apply(step, result, secrets)
      result
    end
    record['visualResults'] = results.map { |result| clean(result, secrets) } unless results.empty?
    record['ok'] = false if results.any? { |result| result[:status] != 'pass' }
    record
  end

  def judge_step(step, spec, root, suite, case_id, evidence_dir, runner)
    limit = spec && spec[:maxDiffRatio]
    actual = step['screenshot'].is_a?(String) ? Base64.decode64(step['screenshot']) : nil
    base = { step: step['index'], name: step['visual']['name'].to_s, viewport: nil, max_diff_ratio: limit }
    base[:viewport] = "#{Integer(step['visual']['width'])}x#{Integer(step['visual']['height'])}"
    return base.merge(status: 'blocked', note: 'no compiled step matches this result') unless limit.is_a?(Numeric) && limit.between?(0, 1)
    return base.merge(status: 'blocked', note: 'the capture returned no image') unless pixels?(actual)

    path = path_for(root, suite: suite, case_id: case_id, name: base[:name], viewport: base[:viewport])
    base[:baseline_path] = relative(File.realpath(root), path)
    stored = read(path)
    return missing(base, evidence_dir, path) unless stored
    return base.merge(status: 'blocked', note: "#{base[:baseline_path]} is not a PNG with pixels") unless pixels?(stored)

    compare(base, stored, actual, evidence_dir, runner)
  rescue Unsafe, ArgumentError, TypeError, SystemCallError => e
    base.merge(status: 'blocked', note: "baseline refused: #{e.message}")
  end

  def pixels?(bytes) = png_size(bytes)&.all?(&:positive?) == true

  def missing(base, evidence_dir, path)
    candidate = evidence_dir ? candidate_name(base[:step], base[:name]) : nil
    base.merge(status: 'blocked', candidate: candidate, promote: promote(evidence_dir, candidate, path),
               note: "no baseline at #{base[:baseline_path]}; it is never accepted automatically")
  end

  def compare(base, stored, actual, evidence_dir, runner)
    return base.merge(status: 'blocked', note: 'the pinned diff container is unavailable') unless runner

    code = DIFF_JS.sub('__INPUT__') { JSON.generate(baseline: Base64.strict_encode64(stored), actual: Base64.strict_encode64(actual), tolerance: PIXEL_TOLERANCE) }
    out = runner.call(code)
    return base.merge(status: 'blocked', note: 'the diff container returned no result') unless out.is_a?(Hash)
    return base.merge(status: 'fail', note: "size mismatch: baseline #{out['baseline'].join('x')}, actual #{out['actual'].join('x')}") if out['sizeMismatch']

    total, differing = Integer(out['total']), Integer(out['differing'])
    raise ArgumentError, 'the diff counts are out of range' unless total.positive? && differing.between?(0, total)

    ratio = differing.to_f / total
    limit = base[:max_diff_ratio]
    status = ratio <= limit ? 'pass' : 'fail'
    base.merge(status: status, differing: differing, total: total, diff_ratio: ratio.round(6), files: keep_files(evidence_dir, base, stored, out['diff']),
               note: status == 'pass' ? nil : "#{differing} of #{total} pixels differ (#{(ratio * 100).round(3)}%), over the allowed #{limit}")
  rescue StandardError => e
    base.merge(status: 'blocked', note: "the diff container failed: #{e.message}")
  end

  def keep_files(dir, base, stored, diff)
    return {} unless dir && Dir.exist?(dir)

    stem = "visual-#{step_number(base[:step])}-#{ChangeTestcasesEvidence.slug(base[:name])}"
    files = { 'baseline' => "#{stem}.baseline.png", 'diff' => "#{stem}.diff.png" }
    File.binwrite(File.join(dir, files['baseline']), stored)
    File.binwrite(File.join(dir, files['diff']), Base64.decode64(diff.to_s))
    files.merge('actual' => candidate_name(base[:step], base[:name]))
  end

  def candidate_name(index, name)
    "shot-#{step_number(index)}-#{ChangeTestcasesEvidence.slug(name)}.png"
  end

  def step_number(index) = format('%04d', index.to_i + 1)

  # The command a person runs to accept the candidate as the baseline.
  def promote(evidence_dir, candidate, path)
    return nil unless evidence_dir && candidate

    "mkdir -p #{Shellwords.escape(File.dirname(path))} && cp #{Shellwords.escape(File.join(evidence_dir, candidate))} #{Shellwords.escape(path)}"
  end

  # A non-pass result fails its step with one redacted line.
  def apply(step, result, secrets)
    return if result[:status] == 'pass'

    prefix = result[:status] == 'blocked' ? 'blocked_precondition' : 'visual diff'
    step['ok'] = false
    step['error'] = "#{prefix}: #{ChangeSelectorSuggestions.safe(result[:note], secrets: secrets, max: 300)}"
  end

  # Free-text fields clipped and redacted; file names and counts left exact.
  def clean(result, secrets)
    result.to_h do |key, value|
      [ key.to_s, %i[note name baseline_path].include?(key) ? ChangeSelectorSuggestions.safe(value, secrets: secrets, max: 300) : value ]
    end.compact
  end

  def relative(base, path) = path.delete_prefix("#{base}/")

  private_class_method :judge_step, :pixels?, :missing, :compare, :keep_files, :candidate_name, :step_number, :promote, :apply, :clean, :relative
end
