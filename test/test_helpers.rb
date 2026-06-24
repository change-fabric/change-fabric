#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

SKILL_SCRIPTS = File.expand_path("../scripts", __dir__)
%w[skill_registry skill_store review_queue skill_inject skill_detect skill_review skill_route slop_remind]
  .each { |name| require_relative "#{SKILL_SCRIPTS}/#{name}" }

REPO_SKILLS = File.expand_path("../skills", __dir__)

# Redirects HOME to a temp dir so session state under ~/.claude/pst is isolated.
module SkillTempHome
  def setup
    @home = Dir.mktmpdir
    @prev_home = Dir.home
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @prev_home
    FileUtils.remove_entry(@home)
  end
end

# Builds throwaway skill directories so matching/detection edge cases can be
# exercised without depending on the shipped cheat sheets.
module SkillFactory
  def skill_dir(name, auto:, body: "BODY-#{name}")
    front = { "name" => name, "description" => "x", "auto" => auto }
    write_skill(name, "---\n#{front.to_yaml.sub(/\A---\n/, '')}---\n\n#{body}\n")
  end

  def plain_skill(name)
    write_skill(name, "---\nname: #{name}\ndescription: plain\n---\n\nNo auto block.\n")
  end

  def write_skill(name, contents)
    dir = File.join(@skills, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), contents)
  end
end
