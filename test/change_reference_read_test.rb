# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "socket"
require_relative "../scripts/change_reference_read"

# Host-side reference reads (suite_version 6): the allowlist, the address
# checks, GET-only with no redirects, the timeout and size cap, JSON only, the
# skew rule, and the bridge that hands the answer to the browser call. The
# policy tests drive the fetch seam; the redirect, size, timeout and JSON tests
# run the real HTTP path against a local socket.
class ChangeReferenceReadTest < Minitest::Test
  Reader = ChangeReferenceRead

  def host(text) = Reader.parse_host(text)

  def reader(hosts: [ host("api.example.org") ], resolver: ->(_name) { [ "93.184.216.34" ] }, fetch: nil, clock: nil, **opts)
    Reader.new(hosts: hosts, resolver: resolver, fetch: fetch, clock: clock, **opts)
  end

  def json_fetch(body = { "members" => { "total" => 70 } }, status: 200, type: "application/json")
    ->(_uri, _address, _timeout, _cap) { [ status, type, JSON.generate(body) ] }
  end

  # --- allowlist and scheme -----------------------------------------------------------

  def test_a_host_the_invocation_did_not_allowlist_is_refused
    error = assert_raises(Reader::Refused) { reader.read(url: "https://other.example.org/x", json_path: "$.a") }
    assert_includes error.message, "--reference-host other.example.org"
  end

  def test_no_allowlist_at_all_refuses_every_host
    plain = reader(hosts: [])
    refute plain.allowed?
    assert_raises(Reader::Refused) { plain.read(url: "https://api.example.org/x", json_path: "$.a") }
  end

  def test_http_is_refused_unless_the_host_is_listed_for_it
    assert_raises(Reader::Refused) { reader(fetch: json_fetch).read(url: "http://api.example.org/x", json_path: "$.members.total") }
    ok = reader(hosts: [ host("api.example.org=http") ], fetch: json_fetch)
    assert_equal 70, ok.read(url: "http://api.example.org/x", json_path: "$.members.total").value
  end

  def test_parse_host_reads_flags_and_refuses_unknown_ones
    parsed = host("API.Example.org=private,http")
    assert_equal "api.example.org", parsed.name
    assert parsed.allow_private
    assert parsed.allow_http
    refute host("api.example.org").allow_private
    assert_raises(Reader::Error) { host("api.example.org=everything") }
    assert_raises(Reader::Error) { host("") }
    assert_raises(Reader::Error) { host("https://api.example.org") }
  end

  def test_a_url_that_is_not_http_is_refused
    assert_raises(Reader::Refused) { reader.read(url: "file:///etc/passwd", json_path: "$") }
    assert_raises(Reader::Refused) { reader.read(url: "not a url", json_path: "$") }
  end

  # --- addresses ------------------------------------------------------------------------

  def test_private_loopback_and_link_local_addresses_are_refused_in_every_form
    %w[10.0.0.5 172.16.4.4 192.168.1.1 127.0.0.1 169.254.169.254 100.64.0.1 0.0.0.0 ::1 fe80::1 fc00::5 ::ffff:127.0.0.1 ::ffff:10.1.2.3].each do |address|
      assert Reader.private_address?(address), address
      denied = reader(resolver: ->(_name) { [ address ] }, fetch: json_fetch)
      assert_raises(Reader::Refused, address) { denied.read(url: "https://api.example.org/x", json_path: "$.members.total") }
    end
    %w[93.184.216.34 8.8.8.8 2606:4700:4700::1111].each { |address| refute Reader.private_address?(address), address }
  end

  def test_a_name_with_any_private_address_is_refused_even_when_another_is_public
    mixed = reader(resolver: ->(_name) { [ "93.184.216.34", "10.0.0.5" ] }, fetch: json_fetch)
    assert_raises(Reader::Refused) { mixed.read(url: "https://api.example.org/x", json_path: "$.members.total") }
  end

  def test_a_host_listed_private_may_resolve_to_a_private_address
    allowed = reader(hosts: [ host("api.example.org=private") ], resolver: ->(_name) { [ "10.0.0.5" ] }, fetch: json_fetch)
    assert_equal 70, allowed.read(url: "https://api.example.org/x", json_path: "$.members.total").value
  end

  def test_the_connection_is_made_to_the_address_that_was_checked
    seen = nil
    fetch = lambda do |uri, address, _timeout, _cap|
      seen = [ uri.host, address ]
      [ 200, "application/json", "{\"a\":1}" ]
    end
    answers = [ [ "93.184.216.34" ], [ "10.0.0.5" ] ]
    rebinding = reader(resolver: ->(_name) { answers.shift }, fetch: fetch)
    rebinding.read(url: "https://api.example.org/x", json_path: "$.a")
    assert_equal [ "api.example.org", "93.184.216.34" ], seen, "connects to the checked address, keeping the name for TLS"
  end

  def test_an_unresolvable_host_is_refused
    assert_raises(Reader::Refused) { reader(resolver: ->(_name) { [] }).read(url: "https://api.example.org/x", json_path: "$.a") }
  end

  # --- responses --------------------------------------------------------------------------

  def test_a_redirect_is_an_error_not_followed
    redirecting = reader(fetch: json_fetch({}, status: 302))
    error = assert_raises(Reader::Error) { redirecting.read(url: "https://api.example.org/x", json_path: "$.a") }
    assert_includes error.message, "redirect"
  end

  def test_a_non_success_status_and_a_non_json_type_are_errors
    assert_raises(Reader::Error) { reader(fetch: json_fetch({}, status: 500)).read(url: "https://api.example.org/x", json_path: "$.a") }
    html = reader(fetch: json_fetch({ "a" => 1 }, type: "text/html"))
    assert_raises(Reader::Error) { html.read(url: "https://api.example.org/x", json_path: "$.a") }
    bad = reader(fetch: ->(*) { [ 200, "application/json", "not json" ] })
    assert_raises(Reader::Error) { bad.read(url: "https://api.example.org/x", json_path: "$.a") }
  end

  def test_json_path_picks_keys_indexes_and_refuses_what_it_cannot_find
    body = { "members" => { "total" => 70, "names" => [ "ada", " grace " ], "by-role" => { "admin" => 3 } }, "odd key" => 1 }
    fetch = json_fetch(body)
    [ [ "$.members.total", 70 ], [ "$['members']['total']", 70 ], [ "$.members.names", [ "ada", "grace" ] ],
      [ "$.members.names[1]", "grace" ], [ "$.members.by-role.admin", 3 ], [ "$[\"odd key\"]", 1 ] ].each do |path, want|
      assert_equal want, reader(fetch: fetch).read(url: "https://api.example.org/x", json_path: path).value, path
    end
    [ "$.members.missing", "$.members.names[9]", "$.members..total", "$.members total", "$.members" ].each do |path|
      assert_raises(Reader::Error, path) { reader(fetch: fetch).read(url: "https://api.example.org/x", json_path: path) }
    end
  end

  # --- the real HTTP path ------------------------------------------------------------------

  # A one-shot local server; `reply` writes the raw response for the request.
  def serve(reply)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      while (line = client.gets) && line != "\r\n"; end
      reply.call(client)
    ensure
      client&.close
    end
    yield server.addr[1]
  ensure
    thread&.kill
    server&.close
  end

  def local_reader(**opts) = Reader.new(hosts: [ host("127.0.0.1=private,http") ], **opts)

  def respond(client, status, body, type: "application/json", extra: "")
    client.write("HTTP/1.1 #{status}\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n#{extra}Connection: close\r\n\r\n#{body}")
  end

  def test_a_real_get_reads_json_and_never_follows_a_redirect
    serve(->(client) { respond(client, "200 OK", '{"members":{"total":70}}') }) do |port|
      assert_equal 70, local_reader.read(url: "http://127.0.0.1:#{port}/m", json_path: "$.members.total").value
    end
    serve(->(client) { respond(client, "302 Found", "", extra: "Location: http://127.0.0.1:1/other\r\n") }) do |port|
      error = assert_raises(Reader::Error) { local_reader.read(url: "http://127.0.0.1:#{port}/m", json_path: "$.a") }
      assert_includes error.message, "redirect"
    end
  end

  def test_a_response_over_the_cap_is_refused
    serve(->(client) { respond(client, "200 OK", "{\"a\":\"#{'x' * 5000}\"}") }) do |port|
      error = assert_raises(Reader::Error) { local_reader(max_bytes: 1024).read(url: "http://127.0.0.1:#{port}/m", json_path: "$.a") }
      assert_includes error.message, "more than 1024 bytes"
    end
  end

  def test_the_default_cap_is_one_mebibyte_and_the_timeout_five_seconds
    assert_equal 1_048_576, Reader::MAX_BYTES
    assert_equal 5, Reader::TIMEOUT_S
  end

  def test_a_reference_that_does_not_answer_times_out
    serve(->(_client) { sleep 3 }) do |port|
      started = Time.now
      error = assert_raises(Reader::Error) { local_reader(timeout_s: 0.3).read(url: "http://127.0.0.1:#{port}/m", json_path: "$.a") }
      assert_includes error.message, "did not answer"
      assert_operator Time.now - started, :<, 2
    end
  end

  # --- skew ---------------------------------------------------------------------------------

  def test_a_reading_within_the_skew_is_kept_and_carries_both_times
    reading = reader(fetch: json_fetch, clock: -> { 10_500 }).read_paired(url: "https://api.example.org/x", json_path: "$.members.total",
                                                                           page_read_at_ms: 10_000, max_skew_ms: 2000)
    assert_equal 70, reading.value
    assert_equal 10_500, reading.read_at_ms
    assert_match(/\A\d{4}-\d\d-\d\dT.*Z\z/, reading.read_at)
  end

  def test_a_reading_outside_the_skew_is_read_once_more
    times = [ 20_000, 10_400 ]
    calls = 0
    fetch = lambda do |*|
      calls += 1
      [ 200, "application/json", "{\"a\":#{calls}}" ]
    end
    reading = reader(fetch: fetch, clock: -> { times.shift }).read_paired(url: "https://api.example.org/x", json_path: "$.a", page_read_at_ms: 10_000)
    assert_equal 2, calls
    assert_equal 2, reading.value, "the second read is the one kept"
  end

  def test_still_outside_the_skew_after_the_second_read_is_skew
    times = [ 20_000, 30_000 ]
    slow = reader(fetch: json_fetch, clock: -> { times.shift })
    error = assert_raises(Reader::Skew) { slow.read_paired(url: "https://api.example.org/x", json_path: "$.members.total", page_read_at_ms: 10_000) }
    assert_includes error.message, "reference skew"
    assert_empty times, "exactly two reads"
  end

  # --- the bridge --------------------------------------------------------------------------

  def build_bridge(**opts)
    ChangeReferenceBridge.new(reader(fetch: json_fetch({ "members" => { "total" => 70, "owner" => "hunter2" } }), **opts))
  end

  def request(bridge, extra = {})
    JSON.generate({ "token" => bridge.token, "url" => "https://api.example.org/m", "jsonPath" => "$.members.total",
                    "pageReadAt" => (Time.now.to_f * 1000).round, "maxSkewMs" => 60_000 }.merge(extra))
  end

  def test_the_bridge_answers_a_token_holder_with_the_value_and_its_read_time
    bridge = build_bridge
    answer = bridge.answer(request(bridge))
    assert_equal true, answer[:ok]
    assert_equal 70, answer[:value]
    assert_kind_of Integer, answer[:readAtMs]
    assert_equal "http://host.docker.internal:#{bridge.port}/", bridge.endpoint[:url]
  ensure
    bridge&.close
  end

  def test_the_bridge_refuses_a_bad_token_and_a_host_the_allowlist_does_not_hold
    bridge = build_bridge
    assert_equal({ ok: false, error: "bad token" }, bridge.answer(request(bridge, "token" => "guess")))
    denied = bridge.answer(request(bridge, "url" => "https://evil.example.net/x"))
    assert_equal false, denied[:ok]
    assert_includes denied[:error], "not allowlisted"
    assert_equal false, bridge.answer("not json")[:ok]
  ensure
    bridge&.close
  end

  def test_the_bridge_reports_skew_as_a_refusal_and_returns_values_unmasked
    bridge = build_bridge(clock: -> { 1_000_000 })
    skewed = bridge.answer(request(bridge, "pageReadAt" => 1, "maxSkewMs" => 10))
    assert_equal false, skewed[:ok]
    assert_includes skewed[:error], "reference skew"
    leaked = bridge.answer(request(bridge, "jsonPath" => "$.members.owner", "pageReadAt" => 1_000_000))
    assert_equal "hunter2", leaked[:value], "masking happens in the report, after the comparison"
  ensure
    bridge&.close
  end

  def test_the_bridge_serves_a_real_post_over_a_socket
    bridge = build_bridge
    socket = TCPSocket.new("127.0.0.1", bridge.port)
    body = request(bridge)
    socket.write("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    response = socket.read
    assert_includes response, "200 OK"
    assert_equal 70, JSON.parse(response.split("\r\n\r\n", 2).last)["value"]
    other = TCPSocket.new("127.0.0.1", bridge.port)
    other.write("GET / HTTP/1.1\r\n\r\n")
    assert_includes other.read, "not a bridge request"
  ensure
    bridge&.close
  end
end
