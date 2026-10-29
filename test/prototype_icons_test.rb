# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/prototype_icons"

class PrototypeIconsTest < Minitest::Test
  PKG = ChangeDocker::PHOSPHOR_PKG

  def test_docker_argv_is_golden
    argv = PrototypeIcons.docker_argv(PKG, "/cache/icons", user: "1000:1000")
    assert_equal [
      "docker", "run", "--rm", "--add-host", ChangeDocker::HOST_GATEWAY, "--user", "1000:1000", "-w", "/out",
      "-e", "HOME=/tmp", "-e", "npm_config_cache=/tmp/.npm", "-e", "npm_config_update_notifier=false",
      "--mount", "type=bind,\"source=/cache/icons\",target=/out",
      ChangeDocker::NODE_IMAGE, "npm", "pack", "@phosphor-icons/core@2.1.1", "--json"
    ], argv
  end

  def test_integrity_mismatch_raises
    assert PrototypeIcons.verify!(PKG, PKG[:integrity])
    err = assert_raises(PrototypeIcons::IntegrityError) { PrototypeIcons.verify!(PKG, "sha512-bogus") }
    assert_includes err.message, "@phosphor-icons/core@2.1.1"
  end

  def test_parse_pack_skips_npm_noise
    out = "npm notice\n[{\"filename\":\"x.tgz\",\"integrity\":\"sha512-a\"}]\n"
    assert_equal "x.tgz", PrototypeIcons.parse_pack(out)["filename"]
  end

  def test_fetch_skips_when_marker_matches
    Dir.mktmpdir do |dir|
      dest = PrototypeIcons.package_dir(PKG, dir)
      FileUtils.mkdir_p(dest)
      File.write(File.join(dest, PrototypeIcons::MARKER), "#{PKG[:integrity]}\n")
      assert_equal dest, PrototypeIcons.fetch(PKG, dir)
    end
  end

  def with_packages
    Dir.mktmpdir do |dir|
      ph = File.join(dir, "ph")
      FileUtils.mkdir_p(File.join(ph, "assets", "regular"))
      FileUtils.mkdir_p(File.join(ph, "assets", "bold"))
      File.write(File.join(ph, "assets", "regular", "bell.svg"), "<svg>bell</svg>")
      File.write(File.join(ph, "assets", "bold", "bell-bold.svg"), "<svg>bold</svg>")
      si = File.join(dir, "si")
      FileUtils.mkdir_p(File.join(si, "data"))
      FileUtils.mkdir_p(File.join(si, "icons"))
      File.write(File.join(si, "data", "simple-icons.json"), JSON.generate([
        { "title" => "Example Pay", "hex" => "123456", "guidelines" => "https://example.com/brand",
          "license" => { "type" => "CC-BY-4.0", "url" => "https://example.com/l" } },
        { "title" => "Dot.Net", "slug" => "dotnet", "hex" => "512BD4" }
      ]))
      File.write(File.join(si, "icons", "examplepay.svg"), "<svg>pay</svg>")
      File.write(File.join(si, "icons", "dotnet.svg"), "<svg>net</svg>")
      yield dir, ph, si
    end
  end

  def test_phosphor_lookup_by_weight
    with_packages do |_dir, ph, _si|
      assert_equal "<svg>bell</svg>", PrototypeIcons.phosphor_svg("bell", root: ph)
      assert_equal "<svg>bold</svg>", PrototypeIcons.phosphor_svg("bell", "bold", root: ph)
      assert_raises(PrototypeIcons::IconNotFoundError) { PrototypeIcons.phosphor_svg("nope", root: ph) }
      assert_raises(ArgumentError) { PrototypeIcons.phosphor_svg("bell", "huge", root: ph) }
    end
  end

  def test_simple_icon_carries_license_and_guidelines
    with_packages do |_dir, _ph, si|
      icon = PrototypeIcons.simple_icon("examplepay", root: si)
      assert_equal "<svg>pay</svg>", icon[:svg]
      assert_equal "123456", icon[:hex]
      assert_equal "https://example.com/brand", icon[:guidelines]
      assert_equal "CC-BY-4.0", icon[:license]["type"]
      assert_nil PrototypeIcons.simple_icon("dotnet", root: si)[:license]
    end
  end

  def test_copy_used_copies_only_named_icons
    with_packages do |dir, ph, si|
      dest = File.join(dir, "out")
      PrototypeIcons.copy_used([ { kind: :phosphor, name: "bell" }, { kind: :simple_icons, name: "dotnet" } ], dest,
                               phosphor_root: ph, simple_icons_root: si)
      assert_equal %w[phosphor-bell-regular.svg simple-dotnet.svg], Dir.children(dest).sort
    end
  end

  def test_notices_include_mit_and_trademark_text
    text = PrototypeIcons.notices(phosphor: true, simple_icons: [
      { title: "Example Pay", slug: "examplepay", guidelines: "https://example.com/brand",
        license: { "type" => "CC-BY-4.0", "url" => "https://example.com/l" } }
    ])
    assert_includes text, "Copyright (c) 2023 Phosphor Icons"
    assert_includes text, "MIT License"
    assert_includes text, "CC0 1.0"
    assert_includes text, "Trademark disclaimer"
    assert_includes text, "Example Pay (examplepay) license: CC-BY-4.0 https://example.com/l guidelines: https://example.com/brand"
    refute_includes PrototypeIcons.notices(phosphor: true, simple_icons: []), "Simple Icons"
  end
end
