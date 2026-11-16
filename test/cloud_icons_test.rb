# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "tmpdir"
require "fileutils"
require_relative "../scripts/cloud_icons"

# Covers the provider icon supply: the committed manifest pin, the cache
# marker, slug and alias resolution against the synthetic fake pack, the
# Phosphor fallback, verbatim inlining, and the attribution text. No test
# fetches a real pack or touches Docker.
class CloudIconsTest < Minitest::Test
  FAKE = File.expand_path("fixtures/cloud_icons/fake-pack", __dir__)

  def store = CloudIcons::Store.new("aws" => FAKE)

  def test_aws_manifest_pins_package_version_and_sha512
    m = CloudIcons.manifest("aws")
    assert_equal "@squinch/pack-aws", m["package"]
    assert_equal "0.19.0", m["version"].to_s
    assert_match(%r{\Asha512-[A-Za-z0-9+/]+={0,2}\z}, m["integrity"])
    assert_match(%r{\Ahttps://aws\.amazon\.com/}, m["terms"])
  end

  def test_aws_profile_nests_six_levels_with_official_colors
    groups = CloudIcons.manifest("aws")["groups"]
    assert_equal 6, CloudIcons.manifest("aws")["max_depth"]
    assert_equal 6, groups.values.map { |g| g["depth"] }.max
    groups.each_value do |g|
      assert_match(/\A#\h{6}\z/, g["color"])
      assert_includes %w[solid dashed], g["dash"]
    end
    assert_equal "#8C4FFF", groups.dig("vpc", "color")
  end

  def test_docker_argv_runs_npm_pack_of_the_pin_in_the_pinned_node_image
    argv = PrototypeIcons.docker_argv(CloudIcons.pkg("aws"), "/tmp/cache")
    assert_includes argv, ChangeDocker::NODE_IMAGE
    assert_includes argv, "@squinch/pack-aws@0.19.0"
  end

  def test_cache_counts_only_with_a_matching_integrity_marker
    Dir.mktmpdir do |root|
      refute CloudIcons.cached?("aws", root)
      dir = CloudIcons.pack_dir("aws", root)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, CloudIcons::MARKER), "sha512-stale\n")
      refute CloudIcons.cached?("aws", root)
      File.write(File.join(dir, CloudIcons::MARKER), "#{CloudIcons.pkg('aws')[:integrity]}\n")
      assert CloudIcons.cached?("aws", root)
    end
  end

  def test_an_empty_cache_store_has_no_pack
    Dir.mktmpdir { |root| assert_nil CloudIcons::Store.cache(root).pack("aws") }
  end

  def test_resolve_finds_a_slug_and_an_alias
    rec = CloudIcons.resolve("aws", "fn", store: store)
    assert_equal :pack, rec[:kind]
    assert_equal "function", rec[:slug]
    assert_equal Digest::SHA256.file(File.join(FAKE, "icons", "function.svg")).hexdigest, rec[:sha]
  end

  def test_missing_slug_or_pack_falls_back_to_a_phosphor_glyph
    missing = CloudIcons.resolve("aws", "lambda", store: store)
    assert_equal :fallback, missing[:kind]
    assert_equal "lightning", missing[:glyph]
    offline = CloudIcons.resolve("aws", "unheard-of", store: CloudIcons::Store.new({}))
    assert_equal "cloud", offline[:glyph]
    assert_match(/not cached/, offline[:reason])
  end

  def test_inline_keeps_the_pack_body_verbatim
    out = CloudIcons.inline("aws", "database", instance_id: "db-icon", box: [ 8, 8, 32, 32 ], store: store)
    file = File.read(File.join(FAKE, "icons", "database.svg"))
    assert_includes out, CloudIcons.inner(file)
    assert_includes out, %(data-pack-sha="#{Digest::SHA256.hexdigest(file)}")
    assert_includes out, %(viewBox="0 0 64 64")
    assert_includes out, "https://aws.amazon.com/architecture/icons/"
  end

  def test_inline_fallback_draws_a_palette_glyph
    out = CloudIcons.inline("aws", "rds", instance_id: "x", box: [ 0, 0, 24, 24 ], store: CloudIcons::Store.new({}))
    assert_includes out, %(data-fallback="database")
    assert_includes out, %(fill="var(--ink)")
    refute_includes out, "data-pack-sha"
  end

  def test_inner_raises_without_an_svg_root
    assert_raises(CloudIcons::Error) { CloudIcons.inner("<g/>") }
  end

  def test_notices_cite_provider_terms_not_the_package_license
    text = CloudIcons.notices(%w[aws aws])
    assert_includes text, "https://aws.amazon.com/architecture/icons/"
    assert_includes text, "@squinch/pack-aws@0.19.0"
    refute_match(/CC-BY|Apache|MIT/, text)
    assert_equal 1, text.scan("Terms:").size
  end
end
