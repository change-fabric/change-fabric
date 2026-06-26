# frozen_string_literal: true

require_relative "test_helpers"

# Content-based `require: [{dep: [...]}]` gating: a match stands only when one
# of the named packages appears in a package.json across the tree. Unions
# nested manifests, counts devDependencies, ignores node_modules, and fails
# open when a manifest is unparseable. Includes the shipped pdf/express/
# js-testing/drizzle dependency scenarios.
class SkillRegistryDepTest < Minitest::Test
  include SkillRegistryHelpers

  def dep_skill(deps)
    skill_dir("redis", auto: { "extensions" => [ "js" ], "require" => [ { "dep" => deps } ] })
    load.first
  end

  def test_dep_require_satisfied
    skill = dep_skill(%w[redis ioredis])
    proj = project_with_files("package.json" => pkg(deps: %w[ioredis]), "src/cache.js" => "")
    assert skill.matches?(File.join(proj, "src/cache.js"), root: proj)
  ensure
    FileUtils.remove_entry(proj) if proj
  end

  def test_dep_require_unsatisfied
    skill = dep_skill(%w[redis ioredis])
    proj = project_with_files("package.json" => pkg(deps: %w[pg]), "src/cache.js" => "")
    refute skill.matches?(File.join(proj, "src/cache.js"), root: proj)
  ensure
    FileUtils.remove_entry(proj) if proj
  end

  def test_dep_require_unions_nested_package_json
    skill = dep_skill(%w[redis])
    proj = project_with_files("package.json" => pkg(deps: %w[turbo]),
                              "apps/api/package.json" => pkg(deps: %w[redis]),
                              "apps/api/src/cache.js" => "")
    assert skill.matches?(File.join(proj, "apps/api/src/cache.js"), root: proj)
  ensure
    FileUtils.remove_entry(proj) if proj
  end

  def test_dep_require_counts_dev_dependencies
    skill = dep_skill(%w[redis])
    proj = project_with_files("package.json" => pkg(dev: %w[redis]), "src/cache.js" => "")
    assert skill.matches?(File.join(proj, "src/cache.js"), root: proj)
  ensure
    FileUtils.remove_entry(proj) if proj
  end

  def test_dep_require_fails_open_on_unparseable_only
    skill = dep_skill(%w[redis])
    proj = project_with_files("package.json" => "{ not json", "src/cache.js" => "")
    assert skill.matches?(File.join(proj, "src/cache.js"), root: proj)
  ensure
    FileUtils.remove_entry(proj) if proj
  end

  def test_dep_require_confident_negative_with_empty_deps
    skill = dep_skill(%w[redis])
    proj = project_with_files("package.json" => pkg(deps: []), "src/cache.js" => "")
    refute skill.matches?(File.join(proj, "src/cache.js"), root: proj)
  ensure
    FileUtils.remove_entry(proj) if proj
  end

  def test_dep_require_inert_without_root
    skill = dep_skill(%w[redis])
    assert skill.matches?("/p/src/cache.js")
  end

  def test_dep_require_ignores_node_modules
    skill = dep_skill(%w[redis])
    proj = project_with_files("package.json" => pkg(deps: %w[pg]),
                              "node_modules/redis/package.json" => pkg(deps: %w[redis]),
                              "src/cache.js" => "")
    refute skill.matches?(File.join(proj, "src/cache.js"), root: proj)
  ensure
    FileUtils.remove_entry(proj) if proj
  end

  def test_require_mixes_glob_and_dep
    skill_dir("mix", auto: { "extensions" => [ "js" ],
                             "require" => [ "**/legacy.marker", { "dep" => %w[redis] } ] })
    skill = load.first
    by_dep = project_with_files("package.json" => pkg(deps: %w[redis]), "a.js" => "")
    by_glob = project_with_files("package.json" => pkg(deps: %w[pg]), "legacy.marker" => "", "a.js" => "")
    neither = project_with_files("package.json" => pkg(deps: %w[pg]), "a.js" => "")
    assert skill.matches?(File.join(by_dep, "a.js"), root: by_dep)
    assert skill.matches?(File.join(by_glob, "a.js"), root: by_glob)
    refute skill.matches?(File.join(neither, "a.js"), root: neither)
  ensure
    [ by_dep, by_glob, neither ].each { |d| FileUtils.remove_entry(d) if d }
  end

  def test_shipped_pdf_rendering_gates_on_puppeteer_not_pdfkit
    pdf = SkillRegistry.load(REPO_SKILLS).find { |s| s.name == "pst:pdf-rendering" }
    pup = project_with_files("package.json" => pkg(deps: %w[puppeteer]), "src/invoice.js" => "")
    kit = project_with_files("package.json" => pkg(deps: %w[pdfkit]), "src/invoice.js" => "")
    assert pdf.matches?(File.join(pup, "src/invoice.js"), root: pup)
    refute pdf.matches?(File.join(kit, "src/invoice.js"), root: kit)
  ensure
    [ pup, kit ].each { |d| FileUtils.remove_entry(d) if d }
  end

  def test_shipped_express_gates_on_express_not_fastify
    exp = SkillRegistry.load(REPO_SKILLS).find { |s| s.name == "pst:express-node" }
    e = project_with_files("package.json" => pkg(deps: %w[express]), "src/server.js" => "")
    f = project_with_files("package.json" => pkg(deps: %w[fastify]), "src/server.js" => "")
    assert exp.matches?(File.join(e, "src/server.js"), root: e)
    refute exp.matches?(File.join(f, "src/server.js"), root: f)
  ensure
    [ e, f ].each { |d| FileUtils.remove_entry(d) if d }
  end

  def test_shipped_js_testing_drops_bare_extension_overmatch
    jst = SkillRegistry.load(REPO_SKILLS).find { |s| s.name == "pst:js-testing" }
    proj = project_with_files("package.json" => pkg(dev: %w[vitest]),
                              "src/foo.test.js" => "", "src/foo.js" => "")
    assert jst.matches?(File.join(proj, "src/foo.test.js"), root: proj)
    refute jst.matches?(File.join(proj, "src/foo.js"), root: proj),
           "a non-test .js no longer matches js-testing"
  ensure
    FileUtils.remove_entry(proj) if proj
  end

  def test_shipped_drizzle_covers_db_directory
    drizzle = SkillRegistry.load(REPO_SKILLS).find { |s| s.name == "pst:drizzle" }
    drz = project_with_files("drizzle.config.js" => "", "src/db/client.js" => "", "src/db/migrate.js" => "")
    assert drizzle.matches?(File.join(drz, "src/db/client.js"), root: drz)
    assert drizzle.matches?(File.join(drz, "src/db/migrate.js"), root: drz)
    refute drizzle.matches?(File.join(drz, "src/components/Button.tsx"), root: drz)
  ensure
    FileUtils.remove_entry(drz) if drz
  end
end
