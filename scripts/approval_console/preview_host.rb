# frozen_string_literal: true

require "open3"
require "timeout"
require_relative "../change_docker"
require_relative "../../test/approval_console_preview"

module ApprovalConsole
  # Starts the approval console preview renderer and a browserless-cf container
  # that can reach it, for preview_capture.rb and preview_a11y.rb. The preview
  # runs on the host (the same arrangement as the transition tests) on a port
  # it picks itself, and the container addresses it through the host alias, so
  # nothing here needs a hosts edit or a fixed port. Both are torn down on exit.
  # Run from a checkout: the preview lives under test/.
  module PreviewHost
    PREVIEW = File.expand_path("../../test/approval_console_preview.rb", __dir__)
    START_TIMEOUT = 20

    class Unavailable < StandardError; end

    module_function

    # Server-renderable pages: every type in every server state, plus the four
    # shared-layout pages.
    def routes
      pages = ApprovalConsolePreview::TYPES.flat_map { |type| ApprovalConsolePreview::STATES.map { |state| "/type/#{type}/state/#{state}" } }
      pages + %w[/page/enroll /page/enroll-shown /page/register /page/notice]
    end

    # Yields the browserless session and the preview url the container uses.
    def with_session(&block)
      raise Unavailable, "docker is not available" unless ChangeDocker.available?

      with_preview do |url|
        ChangeDocker.with_browserless(network: nil) { |session| block.call(session, url) }
      end
    end

    def with_preview
      stdin, out, thread = Open3.popen2e("ruby", PREVIEW, "--port", "0", "--bind", "0.0.0.0", "--public-host", ChangeDocker::HOST_ALIAS)
      stdin.close
      url = Timeout.timeout(START_TIMEOUT) { out.gets.to_s[/PREVIEW_URL=(\S+)/, 1] }
      raise Unavailable, "the preview did not start" unless url

      yield url
    ensure
      if thread
        begin
          Process.kill("TERM", thread.pid)
        rescue Errno::ESRCH
          nil
        end
        thread.join
      end
    end
  end
end
