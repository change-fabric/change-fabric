#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'shell_git'
require_relative 'ctx_paths'

# Resolves where a cf:plan planning pair belongs on disk: which area, which
# slug, and the absolute plan.md/goal.md paths under the configured plans
# root. This module is the deterministic half of cf:plan; the model derives
# the slug text and decides whether to ask, this module reports the facts
# (does the area exist, does the slug collide, what is the next free suffix)
# that decision needs. It never writes a file and never deletes one.
module PlanPaths
  # The default lives in the shim's own store, beside ctx, sessions, and bin,
  # the same place every other piece of per-user cf state already lives. This
  # toolkit ships to many developers, so the default must not assume anybody's
  # personal filing system; a developer who keeps plans in their own notes tree
  # points $CF_PLANS_ROOT at it. The env-var-over-a-home-rooted-default shape
  # mirrors client_name_guard.rb's CF_SENSITIVE_TERMS_FILE exactly.
  #
  # The home comes from CtxPaths.expected_home, not Dir.home, so a session
  # launched with a wrong HOME still writes into the real store rather than
  # minting a stray tree. In the repo and in tests no pin exists, so that call
  # degrades to the running home and this is an ordinary ~ expansion.
  def self.default_root = File.join(CtxPaths.expected_home, '.claude', 'cf', 'plans')

  def self.root
    env = ENV['CF_PLANS_ROOT'].to_s
    env.empty? ? default_root : env
  end

  # Mirrors install.rb's SkillName.portable exactly, so the two rules never
  # drift apart: downcase, non-alphanumeric runs to a single hyphen, strip
  # leading and trailing hyphens.
  def self.slugify(text) = text.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/-+/, '-').gsub(/\A-|-\z/, '')

  # The git toplevel basename when cwd is inside a work tree, else the cwd
  # basename, slugified. Returns nil at the home directory or the filesystem
  # root, where inventing an area name would be a guess rather than an
  # inference, so the skill asks instead.
  def self.infer_area(cwd:)
    return nil if bare_root?(cwd)

    toplevel = ShellGit.run(cwd, 'rev-parse', '--show-toplevel')
    name = File.basename(toplevel || cwd)
    slug = slugify(name)
    slug.empty? ? nil : slug
  end

  def self.bare_root?(cwd) = [ Dir.home, '/', '.' ].include?(cwd.to_s)

  # One directory per area directly under the root, one per plan inside it.
  # There is no extra 'plans' segment: the root is already the plans tree, and
  # nesting plans/ under a root that ends in plans/ reads as a typo.
  def self.plans_dir(area) = File.join(root, area.to_s)

  def self.plan_dir(area, slug) = File.join(plans_dir(area), slug.to_s)

  # Collapses the current home directory prefix to '~', so text written into
  # plan.md, goal.md, workflow.js, or the handoff prompt survives being carried
  # to a machine whose home sits under a different literal path (a Mac's
  # /Users/pxt versus a Linux box's /home/exe versus another Mac's /Users/PST).
  # The absolute form these paths start as is still what mkdir and File.exist?
  # need on this machine; only the text rendered into those four artifacts
  # should ever see the tildeized form. A path outside the home is returned
  # unchanged, since there is nothing to collapse.
  def self.tildeize(path)
    home = CtxPaths.expected_home
    str = path.to_s
    str.start_with?("#{home}/") ? str.sub(home, '~') : str
  end

  # The full resolve hash the CLI prints as JSON. Every path field carries a
  # '_tilde' twin: the absolute form for actual filesystem use, the tilde form
  # for anything written into plan.md, goal.md, workflow.js, or the handoff
  # prompt.
  def self.resolve(area:, slug:)
    dir = plans_dir(area)
    target = plan_dir(area, slug)
    plan_md = File.join(target, 'plan.md')
    goal_md = File.join(target, 'goal.md')
    workflow_js = File.join(target, 'workflow.js')
    {
      root:, root_tilde: tildeize(root),
      area: area.to_s, area_dir: dir, area_dir_tilde: tildeize(dir), area_exists: Dir.exist?(dir),
      slug: slug.to_s, plan_dir: target, plan_dir_tilde: tildeize(target), plan_dir_exists: Dir.exist?(target),
      plan_md:, plan_md_tilde: tildeize(plan_md),
      goal_md:, goal_md_tilde: tildeize(goal_md),
      workflow_js:, workflow_js_tilde: tildeize(workflow_js),
      suggested_slug: next_free_slug(area, slug), siblings: siblings(dir)
    }
  end

  # slug-2, slug-3, ... up to slug-99. Raises if every suffix up to 99 is
  # taken, since a run that long past a collision means something else is
  # wrong rather than that the search should keep going.
  def self.next_free_slug(area, slug)
    dir = plans_dir(area)
    return slug.to_s unless Dir.exist?(File.join(dir, slug.to_s))

    (2..99).each do |n|
      candidate = "#{slug}-#{n}"
      return candidate unless Dir.exist?(File.join(dir, candidate))
    end
    raise "no free slug for #{slug.inspect} under #{dir}"
  end

  def self.siblings(dir)
    return [] unless Dir.exist?(dir)

    Dir.children(dir).sort
  end

  # Minimal argv parser for cf's `--flag value` convention: no positional
  # arguments besides the verb, every flag takes exactly one value.
  module CLI
    def self.run(argv, out: $stdout)
      verb, *rest = argv
      flags = parse(rest)
      case verb
      when 'resolve' then resolve(flags, out)
      when 'mkdir' then mkdir(flags, out)
      when 'tildeize' then tildeize(flags, out)
      else
        out.puts('usage: plan_paths.rb resolve --slug S [--area A] | mkdir --area A --slug S | ' \
                  'tildeize --path P')
        exit 2
      end
    end

    # For any absolute path outside plan_paths.rb's own resolve output, notably
    # the repo root passed to the research and writing agents: renders the form
    # to write into plan.md, goal.md, workflow.js, or the handoff prompt.
    def self.tildeize(flags, out)
      path = flags['path']
      if path.to_s.empty?
        out.puts(JSON.generate('error' => 'path_required'))
        exit 2
      end
      out.puts(PlanPaths.tildeize(path))
    end

    def self.resolve(flags, out)
      area = flags['area'] || PlanPaths.infer_area(cwd: Dir.pwd)
      slug = flags['slug']
      if area.nil?
        out.puts(JSON.generate('error' => 'area_unresolved'))
        exit 2
      end
      out.puts(JSON.generate(PlanPaths.resolve(area:, slug:)))
    end

    def self.mkdir(flags, out)
      area = flags['area']
      slug = flags['slug']
      if area.to_s.empty? || slug.to_s.empty?
        out.puts(JSON.generate('error' => 'area_unresolved'))
        exit 2
      end
      dir = PlanPaths.plan_dir(area, slug)
      FileUtils.mkdir_p(dir)
      out.puts(dir)
    end

    def self.parse(args)
      flags = {}
      until args.empty?
        token = args.shift
        key = token.start_with?('--') && token.delete_prefix('--')
        flags[key] = args.shift if key
      end
      flags
    end
  end
end

PlanPaths::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
