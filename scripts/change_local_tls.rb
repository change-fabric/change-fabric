# frozen_string_literal: true

require 'ipaddr'
require 'json'
require 'uri'

# Lets a browser reach a local HTTPS dev app whose CA the container lacks,
# without ever skipping a real certificate. The Chromium flag that ignores
# certificate errors is browser-wide, so it is only allowed when the target is
# local, and the browser module then aborts every HTTPS request to a host
# outside the local allowlist, including redirects and subresources.
module ChangeLocalTls
  module_function

  LAUNCH_ARG = '--ignore-certificate-errors'
  LOCAL_SUFFIXES = %w[.localhost .local .test .internal].freeze
  # Both shapes the toolkit's browserless modules use for their entry point.
  ENTRY = /export default async (?:function )?\(\{ page \}\) (?:=> )?\{/

  # The hosts the bypass may apply to: the target's own host and every
  # add_hosts name pinned to the host or a private address. Raises when the
  # target itself is not local, since then there is nothing safe to allow.
  def allowed_hosts(target_url, add_hosts)
    unless local_host?(target_url, add_hosts)
      raise ArgumentError, 'ignoring HTTPS errors needs a local target (localhost, *.localhost, *.local, *.test, ' \
                           '*.internal, a private IP, or a name add_hosts maps to host-gateway or a private IP); ' \
                           "got #{target_url.inspect}"
    end
    ([ host_of(target_url) ] + Array(add_hosts).map { |entry| entry.split(':', 2).first.downcase })
      .select { |host| local_name?(host, add_hosts) }.uniq
  end

  # Local means a name or address that cannot carry a publicly issued
  # certificate, or one this run explicitly pins to the host or a private
  # address, so ignoring its certificate skips nothing a real user relies on.
  def local_host?(url, add_hosts = [])
    local_name?(host_of(url), add_hosts)
  rescue URI::InvalidURIError
    false
  end

  def local_name?(host, add_hosts)
    return false if host.empty?
    return true if host == 'localhost' || LOCAL_SUFFIXES.any? { |suffix| host.end_with?(suffix) }
    return true if private_ip?(host)

    Array(add_hosts).any? do |entry|
      name, target = entry.split(':', 2)
      name.downcase == host && (target == 'host-gateway' || private_ip?(target))
    end
  end

  def private_ip?(value)
    ip = IPAddr.new(value.to_s)
    ip.loopback? || ip.private? || ip.link_local?
  rescue IPAddr::InvalidAddressError
    false
  end

  def host_of(url) = URI(url.to_s).host.to_s.downcase.delete_prefix('[').delete_suffix(']')

  # Chrome upgrades plain http to https first, so a public http URL is blocked
  # too while the bypass is on; it is only for local apps.
  def wrap(code, hosts)
    entry = code[ENTRY] or raise ArgumentError, 'browser module has no recognised entry point; cannot scope the HTTPS bypass'

    code.sub(entry, <<~JS.chomp)
      #{entry}
        // Fetch on the browser target pauses every request from every page,
        // context page, and popup, and is on before this module navigates
        // anything, so no page can race ahead of the guard.
        const cfLocalHosts = #{JSON.generate(hosts)};
        const cfFetch = await page.browser().target().createCDPSession();
        cfFetch.on("Fetch.requestPaused", (event) => {
          const url = new URL(event.request.url);
          // URL.hostname keeps IPv6 brackets; the allowlist is unbracketed.
          const host = url.hostname.replace(/^\\[|\\]$/g, "");
          const blocked = url.protocol === "https:" && !cfLocalHosts.includes(host);
          const reply = blocked
            ? cfFetch.send("Fetch.failRequest", { requestId: event.requestId, errorReason: "AccessDenied" })
            : cfFetch.send("Fetch.continueRequest", { requestId: event.requestId });
          reply.catch(() => {});
        });
        await cfFetch.send("Fetch.enable", { patterns: [{ urlPattern: "*" }] });
    JS
  end
end
