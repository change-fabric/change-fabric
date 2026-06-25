#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'review_queue'

# Completion signal for the review gate. The gate denies a push or PR while files
# changed this session lack a review verdict, and it never clears itself; this is
# what the agent runs after a review returns, to record the verdict and release
# the gate. Keeping the unblock in a separate, explicit step is what makes the
# gate deterministic: a finished review clears it, dispatching the prompt does
# not. The session id is an argument because the agent runs this, not a hook, so
# there is no event on stdin to read it from.
session = ARGV[0].to_s
rows = ReviewQueue.new(session).ack
puts "[pst review] Recorded #{rows.size} file(s) as reviewed; gate released."
