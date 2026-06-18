#!/usr/bin/env ruby
# frozen_string_literal: true
# pst-docker.rb -- track and reap ephemeral OrbStack Docker containers (rule 20).
#
# Usage:
#   pst-docker.rb register <name-or-id>   track a container for session-end reaping
#   pst-docker.rb reap                    stop + rm all tracked containers now
#   pst-docker.rb list                    print tracked container names

require_relative File.join(__dir__, 'hooks', 'pst_common')

cmd  = ARGV[0]
name = ARGV[1]

sid = Pst.session_id
if sid.empty?
  warn 'pst-docker: no session id found; is PST mode active?'
  exit 1
end

docker_dir  = File.join(Pst::HOME, 'docker')
docker_file = File.join(docker_dir, sid)

case cmd
when 'register'
  unless name && !name.empty?
    warn 'usage: pst-docker.rb register <name-or-id>'
    exit 1
  end
  FileUtils.mkdir_p(docker_dir)
  File.open(docker_file, 'a') { |f| f.puts(name) }
  puts "pst-docker: registered #{name}"

when 'reap'
  unless File.exist?(docker_file)
    puts 'pst-docker: nothing to reap'
    exit 0
  end
  containers = File.readlines(docker_file, chomp: true).uniq.reject(&:empty?)
  if containers.empty?
    puts 'pst-docker: nothing to reap'
    FileUtils.rm_f(docker_file)
    exit 0
  end
  containers.each do |c|
    print "pst-docker: stopping #{c}... "
    system('docker', 'stop', c, out: File::NULL, err: File::NULL)
    system('docker', 'rm',   c, out: File::NULL, err: File::NULL)
    puts 'done'
  end
  FileUtils.rm_f(docker_file)

when 'list'
  unless File.exist?(docker_file)
    puts '(no tracked containers)'
    exit 0
  end
  containers = File.readlines(docker_file, chomp: true).uniq.reject(&:empty?)
  containers.empty? ? puts('(no tracked containers)') : puts(containers.join("\n"))

else
  warn "usage: pst-docker.rb register <name-or-id> | reap | list"
  exit 1
end
