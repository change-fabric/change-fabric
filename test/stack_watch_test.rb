# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../scripts/stack_watch"

# Stubs gh with a PATH shim. Each poll pops the next scripted response from a
# queue file; the last response repeats once the queue runs dry.
class StackWatchTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = ENV.fetch("PATH", "")
    ENV["PATH"] = "#{@dir}:#{@path}"
    File.write(File.join(@dir, "gh"), <<~SH)
      #!/bin/sh
      q="#{@dir}/$1.queue"
      n=$(cat "$q.n" 2>/dev/null || echo 0)
      total=$(wc -l < "$q")
      [ "$n" -ge "$total" ] && n=$((total - 1))
      sed -n "$((n + 1))p" "$q"
      echo $((n + 1)) > "$q.n"
    SH
    File.chmod(0o755, File.join(@dir, "gh"))
  end

  def teardown
    ENV["PATH"] = @path
    FileUtils.remove_entry(@dir)
  end

  def view(state: "OPEN", head: "aaa", checks: [])
    { state:, mergedAt: state == "MERGED" ? "2026-11-05T00:00:00Z" : nil, headRefOid: head,
      statusCheckRollup: checks }
  end

  # Each entry is [id, resolved] or a bare resolved flag (id derived from position).
  def threads(*entries, next_cursor: nil)
    nodes = entries.each_with_index.map do |entry, i|
      id, resolved = entry.is_a?(Array) ? entry : [ "t#{i}", entry ]
      { id:, isResolved: resolved }
    end
    page = { nodes:, pageInfo: { hasNextPage: !next_cursor.nil?, endCursor: next_cursor } }
    { data: { repository: { pullRequest: { reviewThreads: page } } } }
  end

  def script(views, thread_sets = [ threads ])
    File.write(File.join(@dir, "pr.queue"), views.map { |v| JSON.generate(v) }.join("\n") + "\n")
    File.write(File.join(@dir, "api.queue"), thread_sets.map { |t| JSON.generate(t) }.join("\n") + "\n")
  end

  def watch(*extra)
    out = StringIO.new
    code = StackWatch::CLI.run([ "--pr", "12", "--repo", "acme/web", "--interval", "0", *extra ], out:)
    [ code, JSON.parse(out.string) ]
  end

  def test_merged_exits_zero
    script([ view, view(state: "MERGED") ])
    code, event = watch
    assert_equal [ 0, "merged" ], [ code, event["event"] ]
  end

  def test_closed_exits_three
    script([ view, view(state: "CLOSED") ])
    assert_equal 3, watch.first
  end

  def test_foreign_push_exits_four_but_expected_sha_does_not
    script([ view, view(head: "bbb") ])
    assert_equal 4, watch.first
    script([ view, view(head: "bbb"), view(head: "bbb", state: "MERGED") ])
    assert_equal 0, watch("--expect-sha", "bbb").first
  end

  def test_new_thread_exits_five
    script([ view ], [ threads(true), threads(true, false) ])
    assert_equal 5, watch.first
  end

  def test_swapped_thread_with_same_count_exits_five
    script([ view ], [ threads([ "a", false ], [ "b", true ]), threads([ "a", true ], [ "b", false ]) ])
    code, event = watch
    assert_equal 5, code
    assert_equal [ "b" ], event["opened"]
  end

  def test_threads_paginate_past_first_page
    first = threads([ "a", true ], next_cursor: "c1")
    script([ view ], [ first, threads([ "b", true ]), first, threads([ "b", false ]) ])
    code, event = watch
    assert_equal 5, code
    assert_equal [ "b" ], event["opened"]
  end

  def test_red_check_exits_six
    script([ view(checks: [ { name: "test", conclusion: "FAILURE" } ]) ])
    code, event = watch
    assert_equal 6, code
    assert_equal [ "test" ], event["checks"]
  end

  def test_pending_check_is_not_an_event
    script([ view(checks: [ { name: "test", status: "IN_PROGRESS", conclusion: nil } ]) ])
    assert_equal 7, watch("--ttl", "0").first
  end

  def test_ttl_exits_seven
    script([ view ])
    code, event = watch("--ttl", "1", "--interval", "0.2")
    assert_equal [ 7, "timeout" ], [ code, event["event"] ]
  end

  def test_setup_errors_exit_two
    assert_equal 2, StackWatch::CLI.run([ "--pr", "12" ], out: StringIO.new)
    assert_equal 2, StackWatch::CLI.run([ "--pr", "x", "--repo", "a/b" ], out: StringIO.new)
    File.write(File.join(@dir, "gh"), "#!/bin/sh\nexit 1\n")
    assert_equal 2, watch.first
  end
end
