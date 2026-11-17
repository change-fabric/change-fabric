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

  # The path as the filesystem resolves it, walked one segment at a time the
  # way the kernel does: a symlink is followed before a later `..` applies,
  # so `link/../x` names the link target's parent, not a lexical sibling.
  # Missing segments are kept as given. Never raises. follow_leaf: false
  # keeps a symlink leaf unfollowed.
  def real(path, base: Dir.pwd, follow_leaf: true)
    str = path.to_s
    start = str.start_with?('/') ? '/' : resolve(File.expand_path(base.to_s))
    parts = str.split('/').reject { |seg| seg.empty? || seg == '.' }
    walked = parts.each_with_index.reduce(start) do |cur, (seg, i)|
      next File.dirname(cur) if seg == '..'

      step(File.join(cur, seg), follow: follow_leaf || i < parts.size - 1)
    end
    return resolve(walked) if follow_leaf

    parent = File.dirname(walked)
    parent == walked ? walked : File.join(resolve(parent), File.basename(walked))
  rescue StandardError
    fallback(path, base)
  end

  def step(candidate, follow:)
    return candidate unless follow && File.symlink?(candidate)

    resolve(candidate)
  end

  # True when path is root or inside it, both canonicalized. Compares against
  # root plus a separator, so /a/foobar is not inside /a/foo. Callers that must
  # reject root itself check relative(path, root) != '.'.
  def within?(path, root, follow_leaf: true)
    !relative(path, root, follow_leaf: follow_leaf).nil?
  end

  # within? minus root itself: for callers keying or copying a child of root.
  def strictly_within?(path, root, follow_leaf: true)
    rel = relative(path, root, follow_leaf: follow_leaf)
    !rel.nil? && rel != '.'
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

  private_class_method :resolve, :fallback, :step
end
