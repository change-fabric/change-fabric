#!/usr/bin/env ruby
# frozen_string_literal: true
# PST PostToolUse hook: when an action is taken under Patrick's name (a PR
# created, a PR/issue or Jira comment posted, a Jira issue created, or a
# PR/issue/Jira description updated), open the resulting page in the browser so
# he can see what was posted on his behalf (rule 17). Side effect only; this hook
# NEVER blocks. Inert unless armed. Skip a single run with PST_NO_BROWSER=1.
require_relative 'pst_common'

exit 0 unless Pst.armed?
exit 0 if ENV['PST_NO_BROWSER'] == '1'

payload = Pst.payload
tool = payload['tool_name'].to_s
input = payload['tool_input'] || {}

# Scan only the tool RESPONSE for URLs, so a URL embedded in a comment body (the
# input) is never mistaken for the page that was just posted.
resp = payload['tool_response']
resp_blob = begin
  resp.is_a?(String) ? resp : JSON.generate(resp)
rescue StandardError
  resp.to_s
end

urls = []

if tool == 'Bash'
  cmd = input['command'].to_s
  posting =
    cmd =~ /\bgh\s+(pr|issue)\s+(create|comment)\b/ ||
    (cmd =~ /\bgh\s+(pr|issue)\s+edit\b/ && cmd =~ /--body(-file)?\b/)
  if posting
    # gh prints the canonical URL of the affected PR/issue/comment on stdout.
    urls.concat(resp_blob.scan(%r{https://github\.com/[^\s"'\\),]+}))
    urls.select! { |u| u =~ %r{/(pull|issues)/\d+} || u.include?('#issuecomment') }
  end
elsif tool =~ /Atlassian__(createJiraIssue|editJiraIssue|addCommentToJiraIssue)/
  # Build the human browse URL from the site host in the response plus the issue
  # key (explicit in the input for edit/comment, in the response for create).
  host = resp_blob[%r{https?://([a-z0-9.-]+\.atlassian\.net)}i, 1]
  key = input['issueIdOrKey'].to_s
  key = resp_blob[/\b[A-Z][A-Z0-9]+-\d+\b/].to_s if key.empty?
  urls << "https://#{host}/browse/#{key}" if host && !key.empty?
end

urls = urls.uniq.first(3)
exit 0 if urls.empty?

opener = RUBY_PLATFORM =~ /darwin/ ? 'open' : 'xdg-open'
urls.each { |u| system(opener, u, %i[out err] => File::NULL) }
exit 0
