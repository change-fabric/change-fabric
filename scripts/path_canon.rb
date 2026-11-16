# frozen_string_literal: true

# One way to answer "where does this path really live" and "is it inside that
# root". A check and the action it guards must see the same path: a lexical
# start_with? check followed by a File.read that follows symlinks lets an
# in-tree link point the read anywhere. Containment questions in scripts/ go
# through here (test/path_containment_lint_test.rb enforces it).
#
# No case folding: File.realpath returns the on-disk case, and comparisons
# happen after it. Worktree or cache exclusions stay with the callers.
module PathCanon
  module_function

  # The realpath of the longest existing prefix plus the missing tail, with
  # `..` collapsed. Never raises. follow_leaf: false resolves the parent only
  # and keeps the leaf name as given, so a symlink leaf is not followed.
  def real(path, base: Dir.pwd, follow_leaf: true)
    full = File.expand_path(path.to_s, base.to_s)
    return resolve(full) if follow_leaf

    parent = File.dirname(full)
    parent == full ? full : File.join(resolve(parent), File.basename(full))
  rescue StandardError
    fallback(path, base)
  end

  # True when path is root or inside it, both canonicalized. Compares against
  # root plus a separator, so /a/foobar is not inside /a/foo. Callers that must
  # reject root itself check relative(path, root) != '.'.
  def within?(path, root, follow_leaf: true)
    !relative(path, root, follow_leaf: follow_leaf).nil?
  end

  # The canonical path relative to the canonical root: '.' for root itself,
  # nil when outside. A relative path resolves against root.
  def relative(path, root, follow_leaf: true)
    canon_root = real(root)
    canon = real(path, base: canon_root, follow_leaf: follow_leaf)
    return '.' if canon == canon_root

    prefix = canon_root.end_with?('/') ? canon_root : "#{canon_root}/"
    canon.start_with?(prefix) ? canon.delete_prefix(prefix) : nil
  end

  # Realpath when the path resolves, else the resolved parent plus the leaf.
  # A dangling symlink, a missing path, or an unreadable one all land here.
  def resolve(full)
    File.realpath(full)
  rescue SystemCallError
    parent = File.dirname(full)
    parent == full ? full : File.join(resolve(parent), File.basename(full))
  end

  def fallback(path, base)
    File.expand_path(path.to_s, base.to_s)
  rescue StandardError
    path.to_s
  end

  private_class_method :resolve, :fallback
end
