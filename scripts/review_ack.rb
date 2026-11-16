#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'review_queue'

# Completion signal for the review gate. The gate denies a push or PR while files
# changed this session lack a review verdict, and it never clears itself; this is
# what the agent runs after a review returns, to record the verdict and release
# the gate. Keeping the unblock in a separate, explicit step is what makes the
# gate deterministic: a finished review clears it, dispatching the prompt does
# not. The queue keys are arguments because the agent runs this, not a hook, so
# there is no event on stdin to read them from. A key is a bare session id, a
# session:agent key, or the on-disk name of either; the prompt names each one
# holding rows, and only those named are acked.
keys = ARGV.map(&:to_s).reject(&:empty?)
if keys.empty?
  puts "[cf review] No session id given; nothing recorded, gate unchanged."
else
  rows = keys.flat_map { |key| ReviewQueue.new(key).ack }
  if rows.empty?
    puts "[cf review] Nothing queued for session #{keys.join(' ')}; gate already clear."
  else
    puts "[cf review] Recorded #{rows.size} file(s) as reviewed; gate released."
  end
end
