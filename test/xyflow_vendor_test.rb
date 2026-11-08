# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "json"
require_relative "../scripts/xyflow_vendor"

# The vendored xyflow bundle is the exact file the pinned build produced, it
# credits every package it carries, and nothing in it reaches the network.
class XyflowVendorTest < Minitest::Test
  BUNDLE = WalkthroughDiagram::XYFLOW_BUNDLE
  SIZE_CEILING = 600 * 1024
  # Hosts that appear in the bundle only as string literals: SVG and XML
  # namespaces, React's error-decoder link, and React Flow's attribution and
  # error-doc links. None is fetched.
  INERT_HOSTS = %w[www.w3.org react.dev reactflow.dev ${t}flow.dev].freeze

  def bundle = @bundle ||= File.binread(BUNDLE)

  def test_the_bundle_matches_the_pinned_sha256
    assert_equal WalkthroughDiagram::XYFLOW_SHA256, Digest::SHA256.hexdigest(bundle)
  end

  def test_the_filename_carries_the_pinned_version
    assert_equal "xyflow-#{WalkthroughDiagram::XYFLOW_VERSION}.min.js", File.basename(BUNDLE)
  end

  def test_the_build_inputs_pin_the_same_version
    pkg = JSON.parse(File.read(File.join(XyflowVendor::BUILD_DIR, "package.json")))
    assert_equal WalkthroughDiagram::XYFLOW_VERSION, pkg.dig("dependencies", "@xyflow/react")
    lock = JSON.parse(File.read(File.join(XyflowVendor::BUILD_DIR, "package-lock.json")))
    lock.fetch("packages").each do |path, entry|
      next if path.empty?

      assert_match(/\Asha512-/, entry["integrity"].to_s, "#{path} is not integrity pinned")
    end
  end

  def test_the_bundle_stays_under_the_size_ceiling
    assert_operator bundle.bytesize, :<=, SIZE_CEILING
  end

  def test_the_bundle_is_a_production_classic_iife_exposing_cf_xyflow
    assert bundle.start_with?("(()=>{"), "expected a classic IIFE"
    assert_includes bundle, "window.CfXyflow"
    refute_match(/\bexport\s*\{/, bundle)
    refute_includes bundle, "react.dev/link/", "the development build of React was bundled"
  end

  def test_licenses_name_every_bundled_package
    licenses = File.read(XyflowVendor::LICENSES)
    %w[react react-dom scheduler @xyflow/react @xyflow/system zustand classcat
       use-sync-external-store d3-drag d3-zoom d3-selection d3-interpolate
       d3-color d3-dispatch d3-ease d3-timer d3-transition @dagrejs/dagre].each do |name|
      assert_match(/^--- #{Regexp.escape(name)}@/, licenses, "#{name} is not credited")
    end
  end

  def test_the_bundle_fetches_nothing_remote
    refute_match(/import\(\s*["'`]https?:/, bundle)
    refute_match(/\bfetch\(/, bundle)
    hosts = bundle.scan(%r{https?://([^/"'`?)\s]+)}).flatten.uniq
    assert_empty hosts - INERT_HOSTS, "unexpected remote hosts in the bundle"
  end
end
