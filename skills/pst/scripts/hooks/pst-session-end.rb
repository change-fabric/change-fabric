#!/usr/bin/env ruby
# frozen_string_literal: true
# PST SessionEnd hook: disarm session and reap tracked Docker containers (rule 20).
require_relative 'pst_common'

sid = Pst.session_id
unless sid.empty?
  FileUtils.rm_f(File.join(Pst::HOME, 'armed', sid))

  unless ENV['PST_KEEP_DOCKER'] == '1'
    docker_file = File.join(Pst::HOME, 'docker', sid)
    if File.exist?(docker_file)
      containers = File.readlines(docker_file, chomp: true).uniq.reject(&:empty?)
      containers.each do |name|
        system('docker', 'stop', name, out: File::NULL, err: File::NULL)
        system('docker', 'rm',   name, out: File::NULL, err: File::NULL)
      end
      FileUtils.rm_f(docker_file)
    end
  end
end
