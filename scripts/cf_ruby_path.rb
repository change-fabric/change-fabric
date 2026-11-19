# frozen_string_literal: true

require 'rbconfig'

# The one place a Ruby interpreter path is made stable before it is written to
# a hook command or printed in a hint. RbConfig reports the real, versioned
# Homebrew Cellar directory, which `brew upgrade` plus `brew cleanup` deletes.
# Homebrew keeps `opt/<formula>/bin/<exe>` pointing at the linked version, so
# that is the path worth recording. No dependency on install.rb, so the runtime
# scripts can load it from the installed bin directory.
module CfRubyPath
  # A Cellar interpreter with no usable opt/ link. Never papered over with the
  # Cellar path: nothing written may point into the Cellar.
  class UnstableInterpreter < StandardError; end

  module_function

  # The stable path for `path`: the opt/ link for a Cellar path, `path`
  # unchanged for any other (non-Homebrew) interpreter.
  def stable(path)
    segments = path.split(File::SEPARATOR)
    cellar_index = segments.index('Cellar')
    return path unless cellar_index && segments[cellar_index + 1]

    prefix = segments[0...cellar_index].join(File::SEPARATOR)
    formula = segments[cellar_index + 1]
    candidate = File.join(prefix, 'opt', formula, 'bin', File.basename(path))
    return candidate if File.executable?(candidate)

    raise UnstableInterpreter,
          "Ruby is at #{path}, a versioned Homebrew Cellar path that `brew upgrade` removes, and " \
          "#{candidate} does not exist. Run `brew link ruby`, or reinstall Ruby so that " \
          "$(brew --prefix)/opt/ruby/bin/ruby exists, then retry."
  end

  def current = stable(RbConfig.ruby)
end
