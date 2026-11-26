# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'timeout'
require_relative 'paths'

module Triage
  # Renders and installs the one-shot scheduler entry that runs the bounded,
  # model-free `triage.rb tick` every 15 minutes (C9). A launchd plist on the
  # mini, a systemd user service plus timer on the VM. The entry starts, ticks
  # and exits: it has no KeepAlive and no Restart, so it is a scheduled job and
  # not a host daemon. Actions never run from here; the tick starts them as
  # their own detached one-shot jobs.
  module Scheduler
    LABEL = 'org.change-fabric.triage'
    UNIT = 'cf-triage-tick'
    MINUTES = [ 0, 15, 30, 45 ].freeze
    TICK_SECONDS = 60
    PATH = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'

    Plan = Struct.new(:host, :files, :commands, keyword_init: true)

    # A one-shot watchdog so a hung tick cannot outlive its 60s budget on a
    # scheduler (launchd has no run-time cap of its own).
    module Watchdog
      def self.arm(seconds, exiter: ->(code) { exit!(code) })
        Thread.new do
          sleep(seconds)
          exiter.call(124)
        end
      end
    end

    def self.script = File.join(Dir.home, '.claude', 'cf', 'bin', 'triage.rb')

    def self.render(host, home: Dir.home, ruby: RbConfig.ruby, script: nil, root: nil)
      raise ArgumentError, "unknown host #{host.inspect}" unless Paths::HOSTS.include?(host)

      script ||= File.join(home, '.claude', 'cf', 'bin', 'triage.rb')
      root ||= File.join(home, '.claude', 'cf', 'triage')
      return mini(home, ruby, script, root) if host == 'mini'

      vm(home, ruby, script, root)
    end

    def self.mini(home, ruby, script, root)
      plist = File.join(home, 'Library', 'LaunchAgents', "#{LABEL}.plist")
      Plan.new(host: 'mini', files: { plist => plist_text(home, ruby, script, root) },
               commands: [ [ 'launchctl', 'bootout', "gui/#{Process.uid}/#{LABEL}" ], [ 'launchctl', 'bootstrap', "gui/#{Process.uid}", plist ] ])
    end

    def self.vm(home, ruby, script, root)
      dir = File.join(home, '.config', 'systemd', 'user')
      Plan.new(host: 'vm', files: { File.join(dir, "#{UNIT}.service") => service_text(ruby, script, root),
                                    File.join(dir, "#{UNIT}.timer") => timer_text },
               commands: [ %w[systemctl --user daemon-reload], [ 'systemctl', '--user', 'enable', '--now', "#{UNIT}.timer" ] ])
    end

    def self.plist_text(home, ruby, script, root)
      intervals = MINUTES.map { |minute| "    <dict><key>Minute</key><integer>#{minute}</integer></dict>" }.join("\n")
      <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>#{LABEL}</string>
          <key>ProgramArguments</key>
          <array>
            <string>#{ruby}</string>
            <string>#{script}</string>
            <string>tick</string>
            <string>--max-seconds</string>
            <string>#{TICK_SECONDS}</string>
          </array>
          <key>EnvironmentVariables</key>
          <dict>
            <key>CF_TRIAGE_HOST</key><string>mini</string>
            <key>CF_TRIAGE_ROOT</key><string>#{root}</string>
            <key>HOME</key><string>#{home}</string>
            <key>PATH</key><string>#{PATH}</string>
          </dict>
          <key>StartCalendarInterval</key>
          <array>
        #{intervals}
          </array>
          <key>RunAtLoad</key><false/>
          <key>ExitTimeOut</key><integer>10</integer>
          <key>StandardOutPath</key><string>#{root}/tick.log</string>
          <key>StandardErrorPath</key><string>#{root}/tick.log</string>
        </dict>
        </plist>
      PLIST
    end

    def self.service_text(ruby, script, root)
      <<~UNIT
        [Unit]
        Description=change-fabric triage tick (one-shot)

        [Service]
        Type=oneshot
        Environment=CF_TRIAGE_HOST=vm
        Environment=CF_TRIAGE_ROOT=#{root}
        Environment=PATH=#{PATH}
        ExecStart=#{ruby} #{script} tick --max-seconds #{TICK_SECONDS}
        TimeoutStartSec=#{TICK_SECONDS}
      UNIT
    end

    def self.timer_text
      <<~UNIT
        [Unit]
        Description=change-fabric triage tick every 15 minutes

        [Timer]
        OnCalendar=*:0/15
        Persistent=true
        Unit=#{UNIT}.service

        [Install]
        WantedBy=timers.target
      UNIT
    end

    def self.print(plan_or_hosts, **opts)
      Array(plan_or_hosts).map do |host|
        plan = render(host, **opts)
        plan.files.map { |path, text| "# #{path}\n#{text}" }.join("\n")
      end.join("\n")
    end

    # The live write. Refuses a host this machine cannot be: the mini is
    # Darwin, the vm is Linux. Writes the files, then runs the load commands;
    # bootout of a not-yet-loaded job is allowed to fail.
    def self.install(host, platform: RbConfig::CONFIG['host_os'], runner: method(:run), **opts)
      darwin = platform.include?('darwin')
      raise ArgumentError, "host #{host} cannot be installed from this platform" unless darwin == (host == 'mini')

      plan = render(host, **opts)
      plan.files.each do |path, text|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, text)
      end
      FileUtils.mkdir_p(File.join(opts[:root] || File.join(opts[:home] || Dir.home, '.claude', 'cf', 'triage')))
      plan.commands.each do |command|
        ok = runner.call(command)
        raise "scheduler command failed: #{command.shelljoin}" unless ok || command[1] == 'bootout'
      end
      plan
    end

    def self.run(command)
      _out, status = Open3.capture2e(*command)
      status.success?
    end
  end
end
