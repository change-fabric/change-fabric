#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

SKILL_SCRIPTS = File.expand_path("../scripts", __dir__)
%w[skill_registry skill_store review_queue skill_inject skill_detect skill_review skill_route slop_remind
   render_finding_comment]
  .each { |name| require_relative "#{SKILL_SCRIPTS}/#{name}" }

REPO_SKILLS = File.expand_path("../skills", __dir__)

# Redirects HOME to a temp dir so session state under ~/.claude/cf is isolated.
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

# Shared setup and project builders for the SkillRegistry test files
# (core matching, paths, exclude, require, dep). Each file is a focused
# Minitest::Test that includes this; @skills is a throwaway skills dir.
module SkillRegistryHelpers
  include SkillFactory

  def setup
    @skills = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@skills)
  end

  def load = SkillRegistry.load(@skills)

  # Builds a throwaway project dir holding the given relative files (parents
  # created, contents empty) and returns its path; the caller removes it.
  def project_with(*relpaths)
    dir = Dir.mktmpdir
    relpaths.each do |rel|
      full = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(full))
      FileUtils.touch(full)
    end
    dir
  end

  # Builds a throwaway project from a { relative_path => contents } map, so a
  # case can give package.json real JSON rather than the empty files project_with
  # touches. Caller removes the dir.
  def project_with_files(files)
    dir = Dir.mktmpdir
    files.each do |rel, body|
      full = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
    end
    dir
  end

  # A package.json body listing the given runtime and dev dependencies.
  def pkg(deps: [], dev: [])
    JSON.generate("dependencies" => deps.to_h { |d| [ d, "^1" ] },
                  "devDependencies" => dev.to_h { |d| [ d, "^1" ] })
  end
end
