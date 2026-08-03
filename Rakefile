# frozen_string_literal: true

require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.pattern = 'test/*_test.rb'
  t.warning = true
  # Loaded before any test file, so a suite run started from a git hook (which
  # exports GIT_DIR) cannot let a temp-dir fixture write into the real repo,
  # even in a test file that forgot to require test_helpers.
  t.ruby_opts = %w[-Itest -rgit_fixture]
end

namespace :hooks do
  desc 'Point git at the repo-tracked hooks (runs the CHANGE.md schema drift check pre-commit)'
  task :install do
    sh 'git config core.hooksPath .githooks'
    puts 'git hooks enabled: core.hooksPath -> .githooks'
  end
end

task default: :test
