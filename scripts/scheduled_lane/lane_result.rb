# frozen_string_literal: true

require 'json'

module ScheduledLane
  # The verdict for one run of a lane command. `status` is pass or fail;
  # `failure_class` is nil on pass, else app (the app or its testcases failed)
  # or infra (the lane could not be graded at all).
  Verdict = Struct.new(:status, :failure_class, :notes, :cases, keyword_init: true) do
    def pass? = status == 'pass'
    def to_h = { 'status' => status, 'class' => failure_class, 'notes' => notes, 'cases' => cases }
  end

  # Reads and grades the cf-lane-result/1 file a lane command writes. The
  # verdict comes only from that file plus the exit code: a missing, stale or
  # invalid file is infra, never a pass.
  module LaneResult
    SCHEMA = 'cf-lane-result/1'
    GRADES = %w[pass warn fail].freeze

    module_function

    # `outcome` is a CommandRunner::Outcome; `path` the iteration's result file.
    def classify(outcome, path, run_id)
      return infra("lane command did not run: #{outcome.error}") if outcome.error
      return infra('lane command timed out') if outcome.timed_out

      doc, problem = read(path, run_id)
      return infra(problem) if problem

      grade(doc, outcome.exit_code)
    end

    def grade(doc, exit_code)
      cases = doc['cases']
      failed_exit = exit_code != 0
      if doc['status'] == 'fail'
        Verdict.new(status: 'fail', failure_class: 'app', notes: failed_exit ? [] : [ 'result file reports fail' ], cases: cases)
      elsif failed_exit
        Verdict.new(status: 'fail', failure_class: 'app', notes: [ 'exit/status disagree', "exit #{exit_code}, file says pass" ], cases: cases)
      else
        Verdict.new(status: 'pass', failure_class: nil, notes: [], cases: cases)
      end
    end

    def infra(note) = Verdict.new(status: 'fail', failure_class: 'infra', notes: [ note ], cases: [])

    # [document, nil] when the file is valid for this run, else [nil, reason].
    def read(path, run_id)
      return [ nil, "result file missing: #{path}" ] unless File.file?(path)

      doc = JSON.parse(File.read(path))
      problem = invalid(doc, run_id)
      problem ? [ nil, problem ] : [ doc, nil ]
    rescue JSON::ParserError => e
      [ nil, "result file is not valid JSON: #{e.message[0, 120]}" ]
    end

    def invalid(doc, run_id)
      return 'result file must be a JSON object' unless doc.is_a?(Hash)
      return "result file schema must be #{SCHEMA}" unless doc['schema'] == SCHEMA
      return "result file is stale: run_id #{doc['run_id'].inspect}, expected #{run_id}" unless doc['run_id'] == run_id
      return 'result file status must be pass or fail' unless %w[pass fail].include?(doc['status'])

      case_problem(doc['cases'])
    end

    def case_problem(cases)
      return 'result file cases must be a list' unless cases.is_a?(Array)

      cases.each_with_index do |entry, index|
        return "cases[#{index}] must be an object with a name" unless entry.is_a?(Hash) && entry['name'].is_a?(String)
        return "cases[#{index}].grade must be one of #{GRADES.join(', ')}" unless GRADES.include?(entry['grade'])
        return "cases[#{index}].step_ms must be a number or null" unless entry['step_ms'].nil? || entry['step_ms'].is_a?(Numeric)
      end
      nil
    end
  end
end
