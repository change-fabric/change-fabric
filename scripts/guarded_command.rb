#!/usr/bin/env ruby
# frozen_string_literal: true

require 'shellwords'
require_relative 'merge_mode_slug'

# Advisory guardrail, not airtight enforcement: it inspects the Bash command
# text (plus the current branch, for bare pushes). It catches the obvious cases
# and is trivially bypassable (env-var indirection, non-Bash tools).
# It exists to make an accidental violation of the chosen mode loud, not to
# sandbox.
class GuardedCommand
  TRUNK = %w[main master].freeze

  # Tokenizes like a shell: a quoted string (a commit message, a PR body)
  # collapses into one token instead of leaking its words into the surrounding
  # command - "gh pr edit --body 'run gh pr merge later'" never looks like an
  # invocation of `gh pr merge` - and the operators ; & | && || and newline
  # are their own tokens even when glued to a word (`main;git status`). A
  # redirect such as 2>&1 stays one word. Unbalanced quotes fall back to a
  # whitespace split.
  def self.tokens(command)
    strip_git_globals(raw_tokens(command))
  end

  def self.raw_tokens(command)
    lex(command.to_s)
  rescue ArgumentError
    command.to_s.split
  end

  # git's global options sit between `git` and the subcommand (`git -C dir
  # push`). Those that take a separate value, and the bare flags.
  GIT_VALUE_OPTS = %w[-C -c --git-dir --work-tree --namespace --config-env --super-prefix --attr-source].freeze
  GIT_FLAG_OPTS = %w[--exec-path -p -P --paginate --no-pager --no-replace-objects --bare --literal-pathspecs --glob-pathspecs
                     --noglob-pathspecs --icase-pathspecs --no-optional-locks --no-advice --no-lazy-fetch
                     --html-path --man-path --info-path].freeze

  GIT_EQUALS_OPT = /\A--(exec-path|git-dir|work-tree|namespace|config-env|super-prefix|attr-source)=/

  # Drops git's global options after every `git` token, so the matchers see
  # `git push` however the push is spelled. The skipped options stay available
  # through git_chdirs.
  def self.strip_git_globals(toks)
    out = []
    i = 0
    while i < toks.size
      out << toks[i]
      i += 1
      next unless toks[i - 1] == 'git'

      i = skip_git_globals(toks, i)
    end
    out
  end

  # Index of the first token at or after `i` that is not a git global option.
  def self.skip_git_globals(toks, i)
    while i < toks.size
      tok = toks[i]
      if GIT_VALUE_OPTS.include?(tok)
        i += 2
      elsif GIT_FLAG_OPTS.include?(tok) || tok.match?(GIT_EQUALS_OPT)
        i += 1
      else
        break
      end
    end
    [ i, toks.size ].min
  end

  # The `-C <path>` values given to each `git` in the command, in order.
  def self.git_chdirs(command) = git_invocations(raw_tokens(command)).flat_map { |inv| inv[:chdirs] }

  # The directory a `git ... push` in the command runs in, when `-C` moves it
  # off `base`; nil when no push carries `-C`. Repeated -C compose like git's.
  def self.push_chdir(command, base = Dir.pwd)
    inv = git_invocations(raw_tokens(command)).find { |i| i[:sub] == 'push' && i[:chdirs].any? }
    inv && inv[:chdirs].reduce(base) { |dir, path| File.expand_path(path, dir) }
  end

  # One entry per `git` token: its subcommand and the -C values before it.
  def self.git_invocations(toks)
    toks.each_index.filter_map do |idx|
      next unless toks[idx] == 'git'

      stop = skip_git_globals(toks, idx + 1)
      chdirs = []
      pos = idx + 1
      while pos < stop
        if toks[pos] == '-C'
          chdirs << toks[pos + 1]
          pos += 1
        end
        pos += 1
      end
      { sub: toks[stop], chdirs: chdirs.compact }
    end
  end

  OPERATOR_CHARS = [ ';', '&', '|', "\n" ].freeze

  def self.lex(text)
    out = []
    word = nil
    quote = nil
    i = 0
    while i < text.length
      char = text[i]
      if quote == "'"
        char == "'" ? quote = nil : word << char
      elsif quote == '"'
        if char == '\\' && i + 1 < text.length && '"\\$`'.include?(text[i + 1])
          i += 1
          word << text[i]
        elsif char == '"'
          quote = nil
        else
          word << char
        end
      elsif char == '\\' && i + 1 < text.length
        i += 1
        (word ||= +'') << text[i] unless text[i] == "\n"
      elsif char == "'" || char == '"'
        quote = char
        word ||= +''
      elsif char.match?(/\s/) && char != "\n"
        out << word if word
        word = nil
      elsif OPERATOR_CHARS.include?(char) && !(char == '&' && word&.end_with?('>', '<'))
        out << word if word
        word = nil
        op = char == "\n" ? ';' : char
        op += text[i += 1] if %w[& |].include?(char) && text[i + 1] == char
        out << op
      else
        (word ||= +'') << char
      end
      i += 1
    end
    raise ArgumentError, 'unbalanced quote' if quote

    out << word if word
    out
  end

  # True when `words` appear as an exact contiguous run of tokens.
  def self.invokes?(command, *words)
    tokens(command).each_cons(words.size).any? { |window| window == words }
  end

  def self.push?(command) = invokes?(command, 'git', 'push')
  def self.merge?(command) = invokes?(command, 'gh', 'pr', 'merge')
  def self.pr_create?(command) = invokes?(command, 'gh', 'pr', 'create')

  # A `git push` shaped to plausibly publish a tag: `--tags`/`--follow-tags`,
  # or any positional argument at all beyond `push` itself (a remote, a
  # refspec, `tag <name>`). Deliberately liberal - it does not know which
  # positional is the remote and which is a tag name, since that needs a real
  # repo to resolve (ChangeTagRefs does that). A false positive here costs an
  # extra, cheap resolution attempt that then finds nothing; it never causes an
  # extra deny.
  def self.tag_push?(command)
    return false unless push?(command)

    toks = tokens(command)
    rest = toks[(toks.index('push') + 1)..]
    return true if (rest & %w[--tags --follow-tags]).any?

    rest.any? { |token| !token.start_with?('-') }
  end

  FORCE_FLAGS = %w[-f --force --force-with-lease --force-if-includes --mirror].freeze
  SEPARATORS = %w[&& || ; | &].freeze

  # The argument lists after `push` of every `git ... push` in the command,
  # one per shell segment (split on && || ; | &).
  def self.push_args(command)
    segments(tokens(command)).filter_map do |segment|
      git = segment.index('git') or next
      push = segment.index('push') or next
      segment[(push + 1)..] if push > git
    end
  end

  def self.segments(toks)
    toks.slice_when { |a, b| SEPARATORS.include?(a) || SEPARATORS.include?(b) }.reject { |seg| SEPARATORS.include?(seg.first) }
  end

  # A push argument that forces: a force flag (or `--force-with-lease=...`),
  # a bundle of short flags containing f (`-fu`), or a `+refspec`.
  def self.force_arg?(arg)
    return true if FORCE_FLAGS.include?(arg) || arg.start_with?('--force-with-lease=', '--force-if-includes=')
    return true if arg.match?(/\A-[a-zA-Z]*f[a-zA-Z]*\z/)

    arg.start_with?('+')
  end

  def self.force_push?(command) = push_args(command).any? { |args| args.any? { |arg| force_arg?(arg) } }

  def self.delete_push?(command)
    push_args(command).any? { |args| args.include?('--delete') || args.include?('-d') || args.any? { |arg| arg.start_with?(':') } }
  end

  # `gh release create <tag>`, the other door to publishing a tag: it creates
  # and pushes the tag in one step.
  def self.release_create?(command) = invokes?(command, 'gh', 'release', 'create')

  def initialize(command, mode, branch: nil)
    @command = command.to_s
    # An unrecognized or missing mode falls back to the toolkit's default mode
    # (merge-ready) rather than to no restriction at all.
    @mode = MergeModeSlug.of(mode) || MergeModeSlug::FALLBACK
    @branch = branch.to_s
  end

  def violation
    case @mode
    when 'local-only'
      return 'git push' if push?
      return 'gh pr create' if pr_create?
      return 'gh pr merge' if merge?
    when 'merge-ready'
      return 'a direct push to the trunk' if push_to_trunk?
      return 'gh pr merge' if merge?
    when 'admin-bypass'
      # Deliberately no additional Bash restriction: admin bypass is the mode
      # that permits both the push and the merge.
      nil
    when 'yolo'
      return 'gh pr create' if pr_create?
    end
    nil
  end

  private

  def push?
    self.class.push?(@command)
  end

  def merge?
    self.class.merge?(@command)
  end

  def pr_create?
    self.class.pr_create?(@command)
  end

  # Merge ready allows pushing a feature branch but never the trunk, which would
  # land changes without a PR. An explicit `main`/`master` refspec is a trunk
  # push; so is a bare `git push` while the current branch is the trunk.
  def push_to_trunk?
    return false unless push?

    destinations = push_destinations
    return trunk?(@branch) if destinations.empty?

    destinations.any? { |dest| trunk?(dest) }
  end

  # Branch names the push would update on the remote. A bare push (no refspec)
  # returns [] and is resolved against the current branch by the caller.
  def push_destinations
    toks = self.class.tokens(@command)
    push_index = toks.index('push')
    return [] unless push_index

    positionals = toks[(push_index + 1)..].reject { |t| t.start_with?('-') }
    refspecs = positionals.drop(1) # first positional is the remote
    refspecs.map { |spec| destination_of(spec) }
  end

  def destination_of(refspec)
    dest = refspec.include?(':') ? refspec.split(':', 2).last : refspec
    dest == 'HEAD' ? @branch : dest
  end

  def trunk?(name)
    TRUNK.include?(name.to_s)
  end
end
