# frozen_string_literal: true

require_relative "secret_intake_helpers"
require "socket"
require_relative "../scripts/change_docker"

class SecretIntakePageTest < Minitest::Test
  PUT_URL = "https://s3.us-east-1.amazonaws.com/b/incoming/secret?X-Amz-Signature=abc&x=</script>"

  def html(put_url = PUT_URL, name: "OPENAI_API_KEY")
    SecretIntake::PageRenderer.new.render(put_url: put_url, name: name, expires_at: Time.utc(2030, 1, 1, 13))
  end

  def test_self_contained_with_no_external_urls_but_the_embedded_one
    page = html
    refute_match(/<script[^>]+src/i, page)
    refute_match(/<link[^>]+href/i, page)
    urls = page.scan(%r{https?://[^\s"'<>)]+})
    assert_equal [ "https://s3.us-east-1.amazonaws.com/b/incoming/secret?X-Amz-Signature=abc&x=" ], urls
  end

  def test_embedded_url_cannot_close_the_script
    assert_equal 1, html.scan("</script>").size
    assert_includes html, '<\/script>'
  end

  def test_has_password_input_viewport_and_dark_tokens
    page = html
    assert_includes page, 'type="password"'
    assert_includes page, '<meta name="viewport" content="width=device-width, initial-scale=1">'
    assert_includes page, "@media (prefers-color-scheme: dark)"
    assert_includes page, '"Content-Type": "text/plain"'
    assert_includes page, "2030-01-01 13:00 UTC"
  end

  def test_name_is_escaped
    assert_includes html(name: "<b>X</b>"), "&lt;b&gt;X&lt;/b&gt;"
  end

  # A one-connection-at-a-time HTTP stub on the stdlib (webrick is not in the
  # bundle). It serves the page from the same origin as the PUT, as S3 does,
  # and records every non-GET request (a favicon GET is answered, not kept). Bound on all interfaces so the container
  # reaches it through the host gateway on Linux as well as Docker Desktop.
  class Stub
    attr_reader :origin, :received

    # `page_for` takes the stub's origin and returns the page HTML.
    def initialize(page_for)
      @server = TCPServer.new("0.0.0.0", 0)
      @origin = "http://#{ChangeDocker::HOST_ALIAS}:#{@server.addr[1]}"
      @page, @received = page_for.call(@origin), Queue.new
      @thread = Thread.new { accept_loop }
    end

    def stop
      @server.close
      @thread.join
    end

    private

    def accept_loop
      loop { serve(@server.accept) }
    rescue IOError, Errno::EBADF
      nil
    end

    def serve(client)
      method, path = client.gets.to_s.split
      headers = {}
      while (line = client.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip
      end
      body = client.read(headers["content-length"].to_i)
      return reply(client, "text/html", path == "/b/index.html" ? @page : "") if method == "GET"

      @received << [ method, headers["content-type"], body ]
      reply(client, "text/plain", "")
    ensure
      client.close
    end

    def reply(client, type, body)
      client.write("HTTP/1.1 200 OK\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Connection: close\r\n\r\n#{body}")
    end
  end

  # The real page driven in the pinned browserless Chromium: typing a value and
  # pressing Send PUTs it as text/plain to the embedded URL.
  def test_page_puts_the_value_as_text_plain_against_a_stub
    skip "docker not available" unless ChangeDocker.available?

    stub = Stub.new(->(origin) { html("#{origin}/b/incoming/secret?X-Amz-Signature=abc") })
    begin
      ChangeDocker.with_browserless(network: nil) do |session|
        result = session.run_function(<<~JS)
          export default async function ({ page }) {
            await page.goto(#{JSON.generate("#{stub.origin}/b/index.html")});
            await page.type("#secret", "stub-value-123");
            await page.click("#send");
            await page.waitForFunction(() => document.getElementById("status").className !== "", { timeout: 10000 });
            const status = await page.$eval("#status", (el) => el.className + ":" + el.textContent);
            return { data: { status }, type: "application/json" };
          }
        JS
        assert_match(/\Aok:Sent/, result["status"])
      end
      assert_equal [ "PUT", "text/plain", "stub-value-123" ], stub.received.pop(true)
    ensure
      stub.stop
    end
  end
end
