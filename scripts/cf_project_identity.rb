# frozen_string_literal: true

require 'digest'
require 'open3'
require_relative 'contributors_team'

# Which project a directory belongs to, for anything keyed per project (the
# paid-key store, the sweep trust policy). Three forms, tried in order:
#
#   repo:<host/path>  the normalized git remote, so SSH and HTTPS clones agree
#   git:<root>        the main checkout root from the git common dir, so a
#                     worktree maps to its repo instead of its own path
#   dir:<realpath>    a directory outside any repo is its own project
#
# The prefixes keep the forms from ever colliding. The slug is a fixed-length
# hash of the prefixed id, safe as one path segment.
module CfProjectIdentity
  Identity = Struct.new(:id, :slug, :root, keyword_init: true) do
    def kind = id.split(':', 2).first
    def to_h = { id: id, slug: slug, root: root }
  end

  SLUG_LENGTH = 32

  module_function

  def for(dir)
    kind, value, root = resolve(dir)
    build("#{kind}:#{value}", root)
  end

  # An explicitly named directory (a home dir, an org folder) used as an
  # enrollment level. A checkout root (the main one or a linked worktree)
  # still resolves to its repo; anything else is dir:<realpath>, never the
  # repo it might sit inside.
  def for_explicit_dir(dir)
    real = File.realpath(File.expand_path(dir.to_s))
    return self.for(real) if checkout_root(real) == real

    build("dir:#{real}", real)
  end

  # The unprefixed [kind, value, root] triple. SweepTrustStore keys on the
  # bare value so its existing per-repo records keep their paths.
  def resolve(dir)
    real = File.realpath(File.expand_path(dir.to_s))
    root = git_root(real)
    if root
      repo_id = ContributorsTeam.new(real).repo_id
      return [ 'repo', repo_id, root ] if repo_id && !repo_id.empty?

      return [ 'git', root, root ]
    end
    [ 'dir', real, real ]
  end

  def slug(id) = Digest::SHA256.hexdigest(id.to_s)[0, SLUG_LENGTH]

  def build(id, root) = Identity.new(id: id, slug: slug(id), root: root)

  # The top of the checkout dir sits in (a linked worktree's own root), or nil.
  def checkout_root(dir)
    top = ContributorsTeam.new(dir).repo_root
    top ? File.realpath(top) : nil
  rescue SystemCallError
    nil
  end

  # The main checkout root: the parent of the absolute git common dir, so a
  # linked worktree resolves to the repo it belongs to. nil outside git.
  def git_root(dir)
    out, status = Open3.capture2('git', '-C', dir, 'rev-parse', '--path-format=absolute', '--git-common-dir',
                                 err: File::NULL)
    return nil unless status.success?

    common = out.strip
    return nil if common.empty?

    File.realpath(File.dirname(common))
  rescue SystemCallError
    nil
  end
end
