#!/usr/bin/env ruby
# frozen_string_literal: true
# pst-docker.rb -- track and reap ephemeral OrbStack Docker containers (rule 20).
#
# Usage:
#   pst-docker.rb register <name> [port] [subdomain]   track a container for session-end reaping
#   pst-docker.rb reap                                  stop + rm all tracked containers now
#   pst-docker.rb list                                  print tracked containers (name, port, subdomain)
#
# Record format: one line per container, tab-separated: name<TAB>port<TAB>subdomain
# Legacy bare names (no tabs) remain backward-compatible.
#
# When a subdomain is registered (and is not "localhost"), reap removes the Caddy
# route via the admin API before stopping the container.

require 'json'
require_relative File.join(__dir__, 'hooks', 'pst_common')

CADDY_ADMIN = 'http://localhost:2019'
# Caddy server name used in the admin API path. Default after a fresh Caddy start
# is srv0; override with the CADDY_SERVER env var if your config names it differently.
CADDY_SERVER = ENV.fetch('CADDY_SERVER', 'srv0')

cmd  = ARGV[0]
name = ARGV[1]
port = ARGV[2]
sub  = ARGV[3]

sid = Pst.session_id
if sid.empty?
  warn 'pst-docker: no session id found; is PST mode active?'
  exit 1
end

docker_dir  = File.join(Pst::HOME, 'docker')
docker_file = File.join(docker_dir, sid)

# Parse a stored line into [name, port, subdomain]. Legacy bare names return [name, nil, nil].
def parse_record(line)
  parts = line.split("\t", 3)
  [parts[0], parts[1], parts[2]]
end

# Remove a Caddy route by subdomain via the admin API.
# GETs current routes, filters out the matching one, PUTs the remainder back.
# Prints a warning and continues on any error (Caddy not running, route not found).
def caddy_remove_route(subdomain)
  routes_url = "#{CADDY_ADMIN}/config/apps/http/servers/#{CADDY_SERVER}/routes"

  raw = `curl -sf #{routes_url} 2>/dev/null`
  if raw.nil? || raw.empty?
    warn "pst-docker: Caddy admin API not reachable at #{CADDY_ADMIN} -- skipping route removal for #{subdomain}"
    return
  end

  routes = JSON.parse(raw)
  before = routes.length
  filtered = routes.reject do |r|
    hosts = r.dig('match', 0, 'host') || []
    hosts.include?(subdomain)
  end

  if filtered.length == before
    warn "pst-docker: no Caddy route found for #{subdomain} -- nothing to remove"
    return
  end

  body = JSON.generate(filtered)
  result = system(
    'curl', '-sf', '-X', 'PUT', routes_url,
    '-H', 'Content-Type: application/json',
    '-d', body,
    out: File::NULL, err: File::NULL
  )
  if result
    puts "pst-docker: removed Caddy route for #{subdomain}"
  else
    warn "pst-docker: failed to PUT updated routes to Caddy -- route for #{subdomain} may remain"
  end
rescue JSON::ParserError => e
  warn "pst-docker: could not parse Caddy routes response (#{e.message}) -- skipping route removal for #{subdomain}"
end

case cmd
when 'register'
  unless name && !name.empty?
    warn 'usage: pst-docker.rb register <name> [port] [subdomain]'
    exit 1
  end
  FileUtils.mkdir_p(docker_dir)
  record = [name, port, sub].compact
  line = record.length > 1 ? record.join("\t") : name
  File.open(docker_file, 'a') { |f| f.puts(line) }
  msg = "pst-docker: registered #{name}"
  msg += " port=#{port}" if port && !port.empty?
  msg += " subdomain=#{sub}" if sub && !sub.empty?
  puts msg

when 'reap'
  unless File.exist?(docker_file)
    puts 'pst-docker: nothing to reap'
    exit 0
  end
  records = File.readlines(docker_file, chomp: true).uniq.reject(&:empty?)
  if records.empty?
    puts 'pst-docker: nothing to reap'
    FileUtils.rm_f(docker_file)
    exit 0
  end
  records.each do |rec|
    cname, _cport, csubdomain = parse_record(rec)
    if csubdomain && !csubdomain.empty? && csubdomain != 'localhost'
      caddy_remove_route(csubdomain)
    end
    print "pst-docker: stopping #{cname}... "
    system('docker', 'stop', cname, out: File::NULL, err: File::NULL)
    system('docker', 'rm',   cname, out: File::NULL, err: File::NULL)
    puts 'done'
  end
  FileUtils.rm_f(docker_file)

when 'list'
  unless File.exist?(docker_file)
    puts '(no tracked containers)'
    exit 0
  end
  records = File.readlines(docker_file, chomp: true).uniq.reject(&:empty?)
  if records.empty?
    puts '(no tracked containers)'
  else
    records.each do |rec|
      cname, cport, csubdomain = parse_record(rec)
      parts = [cname]
      parts << "port=#{cport}" if cport && !cport.empty?
      parts << "subdomain=#{csubdomain}" if csubdomain && !csubdomain.empty?
      puts parts.join('  ')
    end
  end

else
  warn 'usage: pst-docker.rb register <name> [port] [subdomain] | reap | list'
  exit 1
end
