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
        const cfLocalHosts = #{JSON.generate(hosts)};
        // Every page gets the guard before the module can navigate it: the
        // first page, any page from browser/context newPage, and popups.
        const cfGuard = async (target) => {
          if (!target || target.__cfLocalTls) return target;
          target.__cfLocalTls = true;
          await target.setRequestInterception(true);
          target.on("request", (request) => {
            const url = new URL(request.url());
            // URL.hostname keeps IPv6 brackets; the allowlist is unbracketed.
            const host = url.hostname.replace(/^\\[|\\]$/g, "");
            if (url.protocol === "https:" && !cfLocalHosts.includes(host)) return request.abort("accessdenied");
            return request.continue();
          });
          return target;
        };
        const cfPatchNewPage = (owner) => {
          const open = owner.newPage.bind(owner);
          owner.newPage = async (...args) => cfGuard(await open(...args));
          return owner;
        };
        const cfBrowser = page.browser();
        cfPatchNewPage(cfBrowser);
        for (const name of ["createBrowserContext", "createIncognitoBrowserContext"]) {
          if (typeof cfBrowser[name] !== "function") continue;
          const create = cfBrowser[name].bind(cfBrowser);
          cfBrowser[name] = async (...args) => cfPatchNewPage(await create(...args));
        }
        cfBrowser.on("targetcreated", async (target) => { if (target.type() === "page") await cfGuard(await target.page()); });
        await cfGuard(page);
    JS
  end
end
