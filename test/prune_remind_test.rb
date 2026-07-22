#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../scripts/prune_remind"

class PruneRemindTest < Minitest::Test
  def context(prompt)
    io = StringIO.new
    PruneRemind.new("prompt" => prompt).emit(io)
    out = io.string
    out.empty? ? nil : JSON.parse(out).dig("hookSpecificOutput", "additionalContext")
  end

  COMPLETED = [
    "I merged PR #6",
    "we just merged that branch",
    "merged pull request 5, now clean up",
    "PR #6 is merged",
    "the pull request was merged",
    "squash-merged it",
    "ok #111 got merged"
  ].freeze

  NOT_COMPLETED = [
    "merge this PR for me",
    "should I merge it?",
    "can you merge the branch",
    "I hit a merge conflict",
    "merging the branch now",
    "leave the unmerged work alone",
    "review the PR before we decide"
  ].freeze

  def test_fires_on_completed_merges
    COMPLETED.each do |prompt|
      refute_nil context(prompt), "expected a reminder for: #{prompt}"
    end
  end

  # Phrasings where "merged" appears but the merge has not happened. Without the
  # negation guard, the SIGNALS would fire on the bare "merged" token.
  NEGATED = [
    "the PR has not been merged yet",
    "we have not merged it yet",
    "I never merged that branch",
    "the PR is merged? not yet"
  ].freeze

  def test_stays_quiet_otherwise
    NOT_COMPLETED.each do |prompt|
      assert_nil context(prompt), "expected no reminder for: #{prompt}"
    end
  end

  def test_stays_quiet_on_negated_merges
    NEGATED.each do |prompt|
      assert_nil context(prompt), "expected no reminder for: #{prompt}"
    end
  end

  def test_reminder_points_at_the_skill
    assert_includes context("I merged #6"), "/cf:prune"
  end

  def test_quiet_on_missing_prompt
    assert_nil context(nil)
    assert_nil context("")
  end
end
