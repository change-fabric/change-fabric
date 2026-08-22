#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require_relative 'guarded_command'

# Answers one question: which [tag, sha] pairs would a given Bash command
# publish? Pure resolution, no policy - `change_tag_guard.rb` is the only
# caller that turns a resolved pair into a gate decision. Every resolution
# failure (no repo, unresolvable ref, git not available) returns [], which
# fails the guard open rather than denying on a fact it could not establish.
class ChangeTagRefs
  # Dispatches on the command shape: a `gh release create` publishes at most
  # one tag; a `git push` may publish several (`--tags`, several refspecs).
  def self.for_command(command, root)
    if GuardedCommand.release_create?(command)
      from_gh_release(command, root)
    elsif GuardedCommand.tag_push?(command)
      from_push(command, root)
    else
      []
    end
  end

  # `git push` forms: explicit refspecs (`origin staging/v1.4.0`,
  # `refs/tags/x`, `origin tag v1.4.0`, `src:dst`), `--tags` (every local tag
  # not already on the remote), and `--follow-tags` (annotated tags reachable
  # from HEAD and not already on the remote).
  def self.from_push(command, root)
    toks = GuardedCommand.tokens(command)
    idx = toks.index('push')
    return [] unless idx

    rest = toks[(idx + 1)..]
    positionals = rest.reject { |token| token.start_with?('-') }
    remote = positionals.first || 'origin'

    pairs = explicit_pairs(positionals, root)
    pairs += new_local_tag_pairs(remote, root) if rest.include?('--tags')
    pairs += follow_tag_pairs(remote, root) if rest.include?('--follow-tags')
    pairs.uniq
  rescue StandardError
    []
  end

  # `gh release create <tag> [--target <sha|branch>]`: the tag usually does
  # not exist locally yet (gh creates it at publish time), so resolution falls
  # back to `--target`, then HEAD - both of which are exactly what `gh
  # release create` itself would tag.
  def self.from_gh_release(command, root)
    toks = GuardedCommand.tokens(command)
    idx = toks.index('release')
    return [] unless idx && toks[idx + 1] == 'create'

    rest = toks[(idx + 2)..]
    tag = rest.reject { |token| token.start_with?('-') }.first
    return [] unless tag

    target = flag_value(rest, '--target')
    sha = resolve_commit(tag, root) || resolve_any(target.to_s.empty? ? 'HEAD' : target, root)
    sha ? [ [ strip_tag_prefix(tag), sha ] ] : []
  rescue StandardError
    []
  end

  # Each explicit positional (remote name, refspec, or a `tag <name>` pair) is
  # tried as a tag; ones that do not resolve as a real tag (a remote name,
  # most of the time) are silently skipped rather than denying anything.
  def self.explicit_pairs(positionals, root)
    pairs = []
    i = 0
    while i < positionals.length
      token = positionals[i]
      if token == 'tag' && positionals[i + 1]
        pairs << pair_for(positionals[i + 1], root)
        i += 2
      elsif token.include?(':')
        pairs << refspec_pair(token, root)
        i += 1
      else
        pairs << pair_for(token, root)
        i += 1
      end
    end
    pairs.compact
  end
  private_class_method :explicit_pairs

  # `src:dst`: the published tag name is `dst` (stripped of `refs/tags/`), but
  # the commit is whatever `src` (a local branch, tag, or commit-ish) resolves
  # to, since `dst` will not exist on the remote until this push lands it.
  def self.refspec_pair(refspec, root)
    src, dst = refspec.split(':', 2)
    name = strip_tag_prefix(dst.to_s)
    return nil if name.empty?

    sha = resolve_any(src.to_s.empty? ? name : src, root)
    sha ? [ name, sha ] : nil
  end
  private_class_method :refspec_pair

  def self.pair_for(name, root)
    sha = resolve_commit(name, root)
    sha ? [ strip_tag_prefix(name), sha ] : nil
  end
  private_class_method :pair_for

  def self.new_local_tag_pairs(remote, root)
    local = run_git(root, 'tag', '-l').to_s.each_line.map(&:strip).reject(&:empty?)
    (local - remote_tag_names(remote, root)).filter_map { |name| pair_for(name, root) }
  end
  private_class_method :new_local_tag_pairs

  def self.follow_tag_pairs(remote, root)
    remote_tags = remote_tag_names(remote, root)
    annotated = annotated_tag_names(root).select { |name| ancestor_of_head?(name, root) }
    (annotated - remote_tags).filter_map { |name| pair_for(name, root) }
  end
  private_class_method :follow_tag_pairs

  def self.annotated_tag_names(root)
    out = run_git(root, 'tag', '-l', '--format=%(objecttype) %(refname:short)')
    return [] unless out

    out.each_line.filter_map do |line|
      type, name = line.strip.split(' ', 2)
      name if type == 'tag' && name
    end
  end
  private_class_method :annotated_tag_names

  def self.ancestor_of_head?(tag, root)
    _out, status = Open3.capture2e('git', '-C', root, 'merge-base', '--is-ancestor', tag, 'HEAD')
    status.success?
  rescue StandardError
    false
  end
  private_class_method :ancestor_of_head?

  def self.remote_tag_names(remote, root)
    out, status = Open3.capture2e('git', '-C', root, 'ls-remote', '--tags', remote.to_s)
    return [] unless status.success?

    out.each_line.filter_map do |line|
      ref = line.split("\t")[1].to_s.strip
      next if ref.empty? || ref.end_with?('^{}')

      ref.delete_prefix('refs/tags/')
    end
  rescue StandardError
    []
  end
  private_class_method :remote_tag_names

  # `git rev-parse <name>^{commit}`, qualified under refs/tags/ unless already
  # given as a full ref, so a same-named branch is never mistaken for a tag.
  # nil on any failure (no such tag, no such repo) so callers fail open.
  def self.resolve_commit(name, root)
    name = name.to_s
    return nil if name.empty?

    ref = name.start_with?('refs/tags/') ? name : "refs/tags/#{name}"
    resolve_any(ref, root)
  end
  private_class_method :resolve_commit

  # Resolves any commit-ish (a branch, a tag, HEAD, a SHA) to the commit it
  # points at, with no refs/tags/ qualification - used for a refspec's source
  # side and `gh release create --target`, neither of which is necessarily a
  # tag itself.
  def self.resolve_any(ref, root)
    ref = ref.to_s
    return nil if ref.empty?

    out, status = Open3.capture2e('git', '-C', root, 'rev-parse', '--verify', "#{ref}^{commit}")
    status.success? ? out.strip : nil
  rescue StandardError
    nil
  end
  private_class_method :resolve_any

  def self.strip_tag_prefix(ref) = ref.start_with?('refs/tags/') ? ref.delete_prefix('refs/tags/') : ref
  private_class_method :strip_tag_prefix

  def self.flag_value(tokens, flag)
    idx = tokens.index(flag)
    idx ? tokens[idx + 1] : nil
  end
  private_class_method :flag_value

  def self.run_git(root, *args)
    out, status = Open3.capture2e('git', '-C', root, *args)
    status.success? ? out : nil
  rescue StandardError
    nil
  end
  private_class_method :run_git
end
