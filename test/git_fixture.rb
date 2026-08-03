# frozen_string_literal: true

require "open3"

# Git-environment isolation for tests that build throwaway repos in temp dirs.
#
# Git locates a repository from environment variables before it looks at the
# working directory, so GIT_DIR (and friends) beat both `git -C <tmpdir>` and
# Dir.chdir. Git also sets those variables when it invokes a hook, and the
# hook's children inherit them: run `bundle exec rake test` from
# .githooks/pre-commit and every fixture that means to write to its own temp
# repo writes to the real one instead. That is how a fixture's
# `git config --local remote.origin.url` and `git config user.name` once
# overwrote this repo's actual origin and identity.
#
# Two defenses live here, because they cover different call sites:
#
#   scrub_env! clears the variables from this process, which is the only thing
#   that helps when the git call is made by the code under test rather than by
#   the fixture (BranchClassify, SkillInject's repo-root lookup, HistoryScrub's
#   preflight all shell out to git themselves).
#
#   CLEAN_ENV overrides them per subprocess, so a fixture's own git calls are
#   isolated even if something re-sets the variables mid-run.
module GitFixture
  # Every variable git consults to locate a repository, index, or object store.
  LOCATION_VARS = %w[
    GIT_DIR
    GIT_WORK_TREE
    GIT_INDEX_FILE
    GIT_OBJECT_DIRECTORY
    GIT_ALTERNATE_OBJECT_DIRECTORIES
    GIT_COMMON_DIR
    GIT_NAMESPACE
    GIT_CEILING_DIRECTORIES
    GIT_DISCOVERY_ACROSS_FILESYSTEM
  ].freeze

  # Passed to every fixture git subprocess: unset the location vars (nil means
  # "remove from the child's environment"), and read neither the developer's
  # global gitconfig nor the machine's system one, so a fixture repo never
  # picks up an unrelated failure from whoever happens to run the suite.
  CLEAN_ENV = LOCATION_VARS.to_h { |name| [ name, nil ] }
                           .merge("GIT_CONFIG_GLOBAL" => File::NULL,
                                  "GIT_CONFIG_SYSTEM" => File::NULL)
                           .freeze

  module_function

  # Removes inherited location vars from this test process, once, at load.
  def scrub_env!
    LOCATION_VARS.each { |name| ENV.delete(name) }
  end

  # Runs git inside an existing fixture repo. Returns combined output; raises
  # on failure, so a broken fixture surfaces as an error rather than as a
  # confusing assertion further down.
  def git(dir, *args)
    run("-C", dir.to_s, *args, label: "git #{args.join(' ')} in #{dir}")
  end

  # Creates a fixture repo at dir. Separate from #git because `git init` takes
  # its target as an argument rather than through -C.
  def git_init(dir, *args)
    run("init", "-q", *args, dir.to_s, label: "git init #{dir}")
  end

  def run(*argv, label:)
    out, status = Open3.capture2e(CLEAN_ENV, "git", *argv)
    raise "#{label} failed: #{out}" unless status.success?

    out
  end
end

GitFixture.scrub_env!
