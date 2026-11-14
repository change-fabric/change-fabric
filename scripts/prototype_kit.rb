#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'fileutils'
require 'optparse'
require 'pathname'
require_relative 'change_docker'
require_relative 'color_compile'
require_relative 'design_config'
require_relative 'design_tokens'

# The durable kit package of a design target (spec 0.18.0): a private
# workspace package, scaffolded once and reused by every prototype, that
# compiles CSS from the app's live theme and renders named presentational
# components and the app shell from live source by server-side rendering
# against typed seed fixtures. Nothing is copied out of the app.
#
#   init  --target <n>   scaffold the kit (refuses to overwrite one)
#   build --target <n>   run the kit's own build in a container with the
#                        workspace root mounted (pnpm symlinks resolve)
#   check --target <n>   compile the kit CSS from the live theme again and
#                        compare custom properties with dist/kit.css; exit 1
#                        on drift, naming each property that differs
#
# The kit depends on app source, never the reverse, and no deployed app may
# depend on it.
module PrototypeKit
  class Error < StandardError; end

  LOCKFILES = { 'pnpm-lock.yaml' => 'pnpm', 'yarn.lock' => 'yarn', 'package-lock.json' => 'npm' }.freeze
  # Framework-only imports SSR cannot load outside the framework, each
  # aliased to a stub the scaffold writes under stubs/.
  STUBS = {
    'next/link' => 'stubs/next-link.tsx',
    'next/image' => 'stubs/next-image.tsx',
    'next/navigation' => 'stubs/next-navigation.ts',
    'server-only' => 'stubs/empty.ts',
    'client-only' => 'stubs/empty.ts'
  }.freeze
  DIST = 'dist'
  KIT_CSS = 'dist/kit.css'
  COMPONENTS_DIR = 'dist/components'
  STDERR_TAIL_LINES = 20

  module_function

  def target_config(root, name)
    config = DesignConfig.load(root).target(name)
    raise Error, "design target '#{config.target.name}' sets no kit; add change_config.design.targets.<n>.kit" unless config.target.kit?

    config
  end

  def kit_dir(root, config) = File.join(root, config.target.kit)
  def dist_dir(root, config) = File.join(kit_dir(root, config), DIST)

  # pnpm, yarn or npm, from the lockfile at the workspace root.
  def package_manager(root)
    LOCKFILES.each { |file, manager| return manager if File.file?(File.join(root, file)) }
    'npm'
  end

  # The nearest directory at or above `path` (inside root) holding a
  # package.json: the app package that owns the theme.
  def owning_package(root, path)
    dir = File.dirname(File.join(root, path))
    while dir.start_with?(root)
      return dir if File.file?(File.join(dir, 'package.json'))
      break if dir == root

      dir = File.dirname(dir)
    end
    root
  end

  def rel(from_dir, to_path) = Pathname.new(to_path).relative_path_from(Pathname.new(from_dir)).to_s

  # --- init -----------------------------------------------------------------

  def init(root, name)
    config = target_config(root, name)
    kit = kit_dir(root, config)
    raise Error, "#{config.target.kit} already exists; the kit is scaffolded once and never overwritten" if File.exist?(kit)

    files = scaffold(root, config)
    files.each do |path, body|
      full = File.join(kit, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
    end
    files.keys
  end

  def scaffold(root, config)
    target = config.target
    kit = kit_dir(root, config)
    app = owning_package(root, target.theme)
    {
      'package.json' => "#{JSON.pretty_generate(package_json(root, config, app))}\n",
      'components.json' => "#{JSON.pretty_generate('render' => [ 'Shell' ])}\n",
      'src/kit.css' => kit_css(root, kit, target, app),
      'src/registry.tsx' => registry_tsx(root, kit, target),
      'src/render.tsx' => RENDER_TSX,
      'build.mjs' => build_mjs(root, kit, app),
      'seed/fixtures.ts' => SEED_TS,
      **STUBS.values.uniq.to_h { |path| [ path, STUB_BODIES.fetch(path) ] }
    }
  end

  def package_json(root, config, app)
    deps = app_dependencies(app)
    pick = ->(*names) { names.to_h { |n| [ n, deps[n] ] }.compact }
    {
      'name' => File.basename(config.target.kit),
      'private' => true,
      'type' => 'module',
      'scripts' => {
        'build' => 'node build.mjs',
        'check' => "ruby ${CF_BIN:-$HOME/.claude/cf/bin}/prototype_kit.rb check --target #{config.target.name} " \
                   "--root #{rel(kit_dir(root, config), root)}"
      },
      'devDependencies' => {
        'esbuild' => deps.fetch('esbuild', '^0.25.0'),
        **pick.call('react', 'react-dom'),
        # The build and check compile kit.css with Tailwind for every source
        # (it resolves the @import and @source), so the compiler is always declared.
        '@tailwindcss/cli' => deps['tailwindcss'] || '^4.0.0',
        'tailwindcss' => deps['tailwindcss'] || '^4.0.0'
      }
    }
  end

  def app_dependencies(app)
    pkg = JSON.parse(File.read(File.join(app, 'package.json')))
    (pkg['devDependencies'] || {}).merge(pkg['dependencies'] || {})
  rescue StandardError
    {}
  end

  # Imports the app's full CSS entry (theme, layers, component CSS), not only
  # its tokens, and names every source Tailwind must scan explicitly: v4
  # auto-detection does not follow workspace symlinks.
  def kit_css(root, kit, target, app)
    src = File.join(kit, 'src')
    sources = [ File.join(app, 'src'), File.join(kit, COMPONENTS_DIR) ]
    sources << File.join(root, target.components) if target.components
    <<~CSS
      /* The kit stylesheet: the app's live CSS entry, never a copy. */
      @import "#{rel(src, File.join(root, target.theme))}";
      #{sources.uniq.map { |s| "@source \"#{rel(src, s)}\";" }.join("\n")}

      /* Fonts the framework injects at runtime (next/font and similar) are not
         in the theme CSS. Declare them here so type renders outside the app.
      @font-face {
        font-family: "App Sans";
        src: url("../fonts/app-sans.woff2") format("woff2");
        font-display: block;
      }
      */
    CSS
  end

  def registry_tsx(root, kit, target)
    import = target.components ? rel(File.join(kit, 'src'), File.join(root, target.components)) : '../src/components'
    <<~TSX
      // Names each component the kit renders to the element it renders with.
      // Components come from live app source; props come from typed seed
      // fixtures. A name in components.json with no entry here fails the build.
      import type { ReactElement } from "react";
      import { seed } from "../seed/fixtures";
      // import { Shell } from "#{import}/shell";

      export const registry: Record<string, () => ReactElement | Promise<ReactElement>> = {
        // Shell: () => <Shell user={seed.user}>{null}</Shell>,
      };

      export { seed };
    TSX
  end

  def build_mjs(root, kit, app)
    alias_root = rel(kit, File.join(app, 'src'))
    <<~JS
      // Kit build: SSR the registry with framework imports stubbed, then compile
      // the kit CSS. Run by `prototype_kit.rb build` in a container with the
      // workspace root mounted; also runnable as the package's own build task.
      import { build } from "esbuild";
      import { execFileSync } from "node:child_process";
      import { mkdirSync } from "node:fs";

      const stubs = #{JSON.pretty_generate(STUBS.transform_values { |v| "./#{v}" })};
      mkdirSync("dist/components", { recursive: true });
      try {
        await build({
          entryPoints: ["src/render.tsx"],
          bundle: true,
          platform: "node",
          format: "esm",
          outfile: "dist/render.mjs",
          jsx: "automatic",
          alias: { ...stubs, "@": "#{alias_root}" },
          packages: "bundle",
          logLevel: "error",
        });
      } catch (error) {
        const unresolved = (error.errors || []).map((e) => e.text).join("\\n");
        console.error(`kit build: unresolved import, add an alias stub:\\n${unresolved}`);
        process.exit(1);
      }
      await import(new URL("./dist/render.mjs", import.meta.url));
      execFileSync("npx", ["--no-install", "@tailwindcss/cli", "-i", "src/kit.css", "-o", "#{KIT_CSS}"], { stdio: "inherit" });
    JS
  end

  RENDER_TSX = <<~TSX
    // Renders every component named in components.json to dist/components/<name>.html.
    // Synchronous components use renderToStaticMarkup; an async server component
    // goes through react-dom/static prerender. Data comes from seed fixtures only.
    import { writeFileSync, readFileSync } from "node:fs";
    import { renderToStaticMarkup } from "react-dom/server";
    import { prerender } from "react-dom/static";
    import { registry } from "./registry";

    const { render } = JSON.parse(readFileSync("components.json", "utf8"));
    for (const name of render as string[]) {
      const make = registry[name];
      if (!make) throw new Error(`components.json names ${name}, which src/registry.tsx does not define`);
      const element = await make();
      let html: string;
      try {
        html = renderToStaticMarkup(element);
      } catch {
        const { prelude } = await prerender(element);
        html = await new Response(prelude).text();
      }
      writeFileSync(`dist/components/${name}.html`, html);
    }
  TSX

  SEED_TS = <<~TS
    // Typed seed fixtures. Type them from the app's own inferred API output
    // types, never a hand-mirrored copy, so a shape change fails the build.
    export const seed = {
      user: { name: "Avery Example", email: "avery@example.org" },
    };
  TS

  STUB_BODIES = {
    'stubs/next-link.tsx' => <<~TSX,
      import type { AnchorHTMLAttributes } from "react";
      export default function Link({ href, ...rest }: AnchorHTMLAttributes<HTMLAnchorElement> & { href: string | { pathname?: string } }) {
        return <a href={typeof href === "string" ? href : href.pathname ?? "#"} {...rest} />;
      }
    TSX
    'stubs/next-image.tsx' => <<~TSX,
      import type { ImgHTMLAttributes } from "react";
      export default function Image({ src, alt, ...rest }: ImgHTMLAttributes<HTMLImageElement> & { src: string | { src: string } }) {
        return <img src={typeof src === "string" ? src : src.src} alt={alt} {...rest} />;
      }
    TSX
    'stubs/next-navigation.ts' => <<~TS,
      export const usePathname = () => "/";
      export const useSearchParams = () => new URLSearchParams();
      export const useParams = () => ({});
      export const useRouter = () => ({ push() {}, replace() {}, refresh() {}, back() {}, prefetch() {} });
      export const redirect = () => {};
      export const notFound = () => {};
    TS
    'stubs/empty.ts' => "export {};\n"
  }.freeze

  # --- build ------------------------------------------------------------------

  # The argv for one kit build: the package manager's own `run build`, in the
  # pinned Node image, with the workspace root mounted so pnpm's symlinked
  # node_modules resolve. Split out so a test asserts it without docker.
  def build_command(root, config)
    kit = config.target.kit
    run = case package_manager(root)
    when 'pnpm' then %w[corepack pnpm run build]
    when 'yarn' then %w[corepack yarn run build]
    else %w[npm run build]
    end
    ChangeDocker.run_command(
      network: nil, image: ChangeDocker::NODE_IMAGE, args: run,
      env: { 'HOME' => '/tmp', 'COREPACK_ENABLE_DOWNLOAD_PROMPT' => '0', 'npm_config_update_notifier' => 'false' },
      mounts: { File.expand_path(root) => '/repo' },
      user: "#{Process.uid}:#{Process.gid}", workdir: "/repo/#{kit}"
    )
  end

  def build(root, name, runner: ->(argv) { Open3.capture2e(*argv) })
    config = target_config(root, name)
    raise Error, "#{config.target.kit} does not exist; run prototype_kit.rb init --target #{config.target.name}" unless Dir.exist?(kit_dir(root, config))

    out, status = runner.call(build_command(root, config))
    raise Error, "kit build failed for #{config.target.name}:\n#{out.to_s.lines.last(STDERR_TAIL_LINES).join}" unless status.success?

    css = File.join(kit_dir(root, config), KIT_CSS)
    raise Error, "kit build wrote no #{KIT_CSS} for #{config.target.name}" unless File.file?(css)

    css
  end

  # --- check ------------------------------------------------------------------

  # Compiles the kit stylesheet again from the live theme and compares every
  # custom property with the built dist/kit.css. Returns DriftFindings; any
  # finding is drift. A kit CSS with no utility rules means Tailwind scanned
  # nothing, which is also a failure.
  def check(root, name, compiler: default_compiler)
    config = target_config(root, name)
    kit = kit_dir(root, config)
    built_path = File.join(kit, KIT_CSS)
    raise Error, "#{File.join(config.target.kit, KIT_CSS)} is missing; run prototype_kit.rb build first" unless File.file?(built_path)

    live = compiler.call(root, File.join(kit, 'src', 'kit.css'), kit)
    raise Error, "live theme compile failed: #{live.error}" if live.error

    built = File.binread(built_path)
    drift = DesignTokens::Drift.compare_properties('kit', DesignTokens::Drift.properties(live.css),
                                                   DesignTokens::Drift.properties(built))
    drift << DesignTokens::Drift.copy_mismatch('kit', nil, nil, nil, "#{KIT_CSS} has no utility rules; check @source lines") unless utilities?(built)
    drift
  end

  def utilities?(css) = css.to_s.match?(/(?:\A|[}\s])\.[A-Za-z_\\][^{]*\{/)

  def default_compiler
    lambda do |root, path, package_root|
      ColorCompile.read(File.expand_path(root), File.expand_path(path), package_root: File.expand_path(package_root))
    end
  end

  # --- CLI --------------------------------------------------------------------

  USAGE = 'usage: prototype_kit.rb init|build|check --target <name> [--root DIR]'

  def cli(argv, out: $stdout, err: $stderr)
    command = argv.first
    opts = { root: Dir.pwd }
    OptionParser.new do |o|
      o.on('--target NAME') { |v| opts[:target] = v }
      o.on('--root DIR') { |v| opts[:root] = v }
    end.parse!(argv.drop(1))
    root = File.expand_path(opts[:root])
    case command
    when 'init' then init(root, opts[:target]).each { |f| out.puts "wrote #{f}" }
    when 'build' then out.puts "built #{build(root, opts[:target])}"
    when 'check'
      findings = check(root, opts[:target])
      findings.each { |f| out.puts f }
      out.puts(findings.empty? ? 'kit is current with the live theme' : "#{findings.size} drift finding(s)")
      return findings.empty? ? 0 : 1
    else
      err.puts USAGE
      return 2
    end
    0
  rescue Error, DesignConfig::Error, OptionParser::ParseError => e
    err.puts "prototype_kit: #{e.message}"
    2
  end
end

exit PrototypeKit.cli(ARGV) if __FILE__ == $PROGRAM_NAME
