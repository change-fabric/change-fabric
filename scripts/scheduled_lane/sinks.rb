# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'command_runner'
require_relative 'lane_config'

module ScheduledLane
  class SinkError < StandardError; end

  # What a sink is told about one lane run. `failure_class` is app, infra or nil.
  Report = Struct.new(:lane_id, :status, :failure_class, :label, :notes, :ref, :env, :release_tag, :run_id, :deployed_sha,
                      :rows, :cases, :run_url, :iterations, :release_sha, keyword_init: true) do
    def pass? = status == 'pass'
  end

  # The markdown every sink posts. The mismatch label, when there is one, leads.
  module SinkBody
    module_function

    def render(report)
      lines = [ headline(report) ]
      lines << "**#{report.label}**" if report.label
      lines.concat(facts(report))
      lines.concat(list('Notes', report.notes))
      lines.concat(case_table(report.cases))
      lines.concat(row_table(report.rows))
      "#{lines.join("\n")}\n"
    end

    def headline(report)
      verdict = report.pass? ? 'pass' : "FAIL (#{report.failure_class})"
      "Lane `#{report.lane_id}`: #{verdict}\n"
    end

    def facts(report)
      pairs = { 'ref' => report.ref, 'env' => report.env, 'release tag' => report.release_tag, 'deployed SHA' => report.deployed_sha,
                'run id' => report.run_id, 'run' => report.run_url }
      pairs.reject { |_, value| value.to_s.empty? }.map { |name, value| "- #{name}: #{value}" } + [ '' ]
    end

    def list(title, items)
      return [] if items.nil? || items.empty?

      [ "#{title}:" ] + items.map { |item| "- #{item}" } + [ '' ]
    end

    def case_table(cases)
      bad = Array(cases).reject { |entry| entry['grade'] == 'pass' }
      return [] if bad.empty?

      [ '| case | grade | step ms | reason |', '| --- | --- | --- | --- |' ] +
        bad.map { |entry| "| #{cell(entry['name'])} | #{cell(entry['grade'])} | #{cell(entry['step_ms'])} | #{cell(entry['reason'])} |" } + [ '' ]
    end

    def row_table(rows)
      return [] if rows.nil? || rows.empty?

      [ '| flag | seed | flip | lane | revert |', '| --- | --- | --- | --- | --- |' ] + rows.map { |row| row_line(row) } + [ '' ]
    end

    def row_line(row)
      lane = row['lane'] ? "#{row['lane']['status']}#{row['lane']['class'] ? " (#{row['lane']['class']})" : ''}" : 'not run'
      "| #{cell(row['key'])} | #{cell(row['seed_state'])} | #{row['flip_ok'] ? 'ok' : 'failed'} | #{lane} | #{revert_cell(row['revert_ok'])} |"
    end

    def revert_cell(value) = value.nil? ? 'n/a' : (value ? 'confirmed' : 'NOT CONFIRMED')

    def cell(value) = value.to_s.gsub('|', '\\|').gsub(/\s+/, ' ').strip
  end

  # The gh CLI. Only stdout is ever parsed; stderr is for the error message.
  class GhClient
    def call(args, stdin: nil)
      out, err, status = Open3.capture3({ 'GH_PROMPT_DISABLED' => '1' }, 'gh', *args, stdin_data: stdin.to_s)
      raise SinkError, "gh #{args.first(2).join(' ')} failed: #{err.strip[0, 300]}" unless status.success?

      out
    rescue SystemCallError => e
      raise SinkError, "gh could not run: #{e.message}"
    end
  end

  # One open issue per (label, marker), found by the label and kept only when
  # its body carries the marker, so an unrelated issue that happens to wear the
  # label is never touched. A create race is settled by searching again.
  class IssueStore
    LIST_LIMIT = '100'

    def initialize(gh)
      @gh = gh
    end

    # Open issues carrying the marker, lowest number first.
    def find(label, marker)
      json = JSON.parse(@gh.call(%w[issue list --label] + [ label, '--state', 'open', '--json', 'number,body', '--limit', LIST_LIMIT ]))
      json.select { |issue| issue['body'].to_s.include?(marker) }.map { |issue| issue['number'] }.sort
    rescue JSON::ParserError
      raise SinkError, 'gh issue list did not print JSON'
    end

    # { number:, created: } for the surviving issue. `created` is true only when
    # the issue this call opened is the survivor, so the caller knows its body
    # already carries the report.
    def ensure(label:, marker:, title:, body:, labels: [])
      found = find(label, marker)
      return { number: settle(found), created: false } unless found.empty?

      mine = create(title, body, [ label ] + labels)
      survivors = find(label, marker)
      survivor = settle(survivors)
      { number: survivor, created: survivor == mine }
    end

    # Keep the lowest number; comment on and close the rest. Returns the kept one.
    def settle(numbers)
      keep, *extra = numbers.sort
      extra.each do |number|
        comment(number, "Duplicate of ##{keep}.\n")
        close(number)
      end
      keep
    end

    def comment(number, body)
      @gh.call([ 'issue', 'comment', number.to_s, '--body-file', '-' ], stdin: body)
    end

    def close(number)
      @gh.call([ 'issue', 'close', number.to_s ])
    end

    def assign(number, login)
      @gh.call([ 'issue', 'edit', number.to_s, '--add-assignee', login ])
    end

    private

    def create(title, body, labels)
      labels.each { |name| @gh.call([ 'label', 'create', name, '--force' ]) }
      args = [ 'issue', 'create', '--title', title, '--body-file', '-' ] + labels.flat_map { |name| [ '--label', name ] }
      url = @gh.call(args, stdin: body)
      number = url[%r{/issues/(\d+)}, 1] || raise(SinkError, 'gh issue create did not print an issue URL')
      number.to_i
    end
  end

  # One open issue per lane, in place: a failure opens it or comments on it, a
  # later pass comments and closes it.
  class GithubIssueSink
    def initialize(config, store)
      @config = config
      @store = store
    end

    def report(report)
      label = "scheduled-lane:#{report.lane_id}"
      marker = "<!-- cf-scheduled-lane:#{report.lane_id} -->"
      body = SinkBody.render(report)
      report.pass? ? recover(label, marker, body) : fail_issue(report, label, marker, body)
    end

    private

    def fail_issue(report, label, marker, body)
      issue = @store.ensure(label: label, marker: marker, title: "Scheduled lane #{report.lane_id} failing",
                            body: "#{marker}\n#{body}", labels: Array(@config['labels']))
      @store.comment(issue[:number], body) unless issue[:created]
      login = @config["assignee_on_#{report.failure_class}_failure"]
      @store.assign(issue[:number], login) if login
    end

    def recover(label, marker, body)
      numbers = @store.find(label, marker)
      return if numbers.empty?

      keep = @store.settle(numbers)
      @store.comment(keep, "Passing again.\n\n#{body}")
      @store.close(keep)
    end
  end

  # Posts the diligence result for a release tag as a comment. It never edits
  # the release body. A release with a linked discussion gets the comment there;
  # otherwise one issue per tag, found by label and marker, carries the thread.
  class ReleaseCommentSink
    LABEL = 'release-diligence'
    DISCUSSION_URL = %r{github\.com/([^/]+)/([^/]+)/discussions/(\d+)}
    DISCUSSION_ID_QUERY = 'query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){discussion(number:$number){id}}}'
    ADD_COMMENT = 'mutation($id:ID!,$body:String!){addDiscussionComment(input:{discussionId:$id,body:$body}){comment{id}}}'

    def initialize(gh, store)
      @gh = gh
      @store = store
    end

    def report(report)
      tag = report.release_tag
      return if tag.to_s.empty?

      body = SinkBody.render(report)
      release = release_for(tag)
      if release && release['discussion_url']
        discussion_comment(release['discussion_url'], body)
      else
        issue_comment(tag, release, body)
      end
    end

    private

    # The release as the REST API describes it, or nil (a draft has no tag page).
    def release_for(tag)
      JSON.parse(@gh.call([ 'api', "repos/{owner}/{repo}/releases/tags/#{tag}" ]))
    rescue SinkError, JSON::ParserError
      nil
    end

    def discussion_comment(url, body)
      owner, name, number = url.match(DISCUSSION_URL)&.captures || raise(SinkError, "unrecognized discussion URL: #{url}")
      found = JSON.parse(@gh.call([ 'api', 'graphql', '-f', "query=#{DISCUSSION_ID_QUERY}", '-f', "owner=#{owner}", '-f', "name=#{name}",
                                    '-F', "number=#{number}" ]))
      id = found.dig('data', 'repository', 'discussion', 'id') || raise(SinkError, "discussion #{number} not found")
      @gh.call([ 'api', 'graphql', '-f', "query=#{ADD_COMMENT}", '-f', "id=#{id}", '-F', 'body=@-' ], stdin: body)
    rescue JSON::ParserError
      raise SinkError, 'gh api graphql did not print JSON'
    end

    def issue_comment(tag, release, body)
      marker = "<!-- cf-release-diligence:#{tag} -->"
      link = release && release['html_url'] ? "Release: #{release['html_url']}" : "Release #{tag} (no published release page found)"
      issue = @store.ensure(label: LABEL, marker: marker, title: "Release diligence #{tag}", body: "#{marker}\n#{link}\n\n#{body}")
      @store.comment(issue[:number], body) unless issue[:created]
    end
  end

  # Pipes the body to a repo-declared command on stdin. Posts nowhere itself.
  class ChatDmSink
    def initialize(config, runner)
      @cmd = config['cmd']
      @runner = runner
    end

    def report(report)
      return if report.pass?

      outcome = @runner.call(@cmd, stdin: SinkBody.render(report))
      raise SinkError, "chat_dm cmd failed: #{outcome.summary}" unless outcome.ok?
    end
  end

  module Sinks
    module_function

    def build(lane, gh: GhClient.new, runner: CommandRunner.new)
      store = IssueStore.new(gh)
      lane.sinks.map do |config|
        case config['type']
        when 'github_issue' then GithubIssueSink.new(config, store)
        when 'release_comment' then ReleaseCommentSink.new(gh, store)
        when 'chat_dm' then ChatDmSink.new(config, runner)
        end
      end
    end

    # Runs every sink; one sink failing never stops the others. Returns the errors.
    def report_all(sinks, report)
      sinks.filter_map do |sink|
        sink.report(report)
        nil
      rescue SinkError => e
        "#{sink.class.name.split('::').last}: #{e.message}"
      end
    end
  end
end
