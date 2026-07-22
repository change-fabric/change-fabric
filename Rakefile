# frozen_string_literal: true

require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.pattern = 'test/*_test.rb'
  t.warning = true
end

namespace :hooks do
  desc 'Point git at the repo-tracked hooks (runs the CHANGE.md schema drift check pre-commit)'
  task :install do
    sh 'git config core.hooksPath .githooks'
    puts 'git hooks enabled: core.hooksPath -> .githooks'
  end
end

task default: :test
