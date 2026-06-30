# frozen_string_literal: true

require "yaml"
require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/ctx_store"

# The .ctx equivalent of skill_length_test: every doc the store produces must
# stay parseable, classed correctly, and within the note budget (tighter than a
# skill's, since these are notes, not authored guidance). Real stores live
# outside the repo, so the fixtures are written into a temp home here.
class CtxLengthTest < Minitest::Test
  include SkillTempHome

  MAX_BODY_LINES = 300
  WARN_BODY_LINES = 200
  MAX_NAME_CHARS = 64
  MAX_DESCRIPTION_CHARS = 1024
  VALID_STATUS = %w[active done superseded archived].freeze

  # Under @home (the redirected HOME), so the store-keying guard accepts it.
  def cwd = File.join(@home, "code", "demo")

  def setup
    super
    store = CtxStore.new(cwd: cwd, home: @home, session_id: "s", device: "dev",
                         committer: ->(_message) { }, now: Time.new(2026, 6, 27))
    store.write(name: "contract", description: "a signed master services agreement", klass: "truth", body: "terms")
    store.write(name: "plan", description: "implementation plan, in flight", klass: "active", body: "steps")
    store.write(name: "scratch", description: "throwaway bootstrap notes", klass: "ephemeral", ttl: "14d", body: "notes")
  end

  def each_doc
    base = CtxPaths.store_dir(cwd, home: @home)
    CtxPaths::CLASSES.each do |klass|
      Dir.glob(File.join(base, klass, "*.md")).sort.each do |path|
        front, body = SkillRegistry::Frontmatter.split(File.read(path))
        yield klass, YAML.safe_load(front), body, path
      end
    end
  end

  def test_frontmatter_parses_and_directory_matches_class
    seen = 0
    each_doc do |klass, meta, _body, path|
      seen += 1
      refute_nil meta, "#{path}: frontmatter did not parse"
      assert_equal klass, meta["class"], "#{path}: directory #{klass} must match frontmatter class"
    end
    assert_equal 3, seen
  end

  def test_status_is_valid
    each_doc { |_klass, meta, _body, path| assert_includes VALID_STATUS, (meta["status"] || "active"), path }
  end

  def test_truth_has_no_ttl_and_ephemeral_has_ttl
    each_doc do |klass, meta, _body, path|
      refute meta.key?("ttl"), "#{path}: a truth doc must not carry a ttl" if klass == "truth"
      assert meta["ttl"], "#{path}: an ephemeral doc must carry a ttl" if klass == "ephemeral"
    end
  end

  def test_body_within_note_budget
    each_doc do |_klass, _meta, body, path|
      lines = body.lines.count
      assert_operator lines, :<=, MAX_BODY_LINES,
                      "#{path}: body is #{lines} lines, over the #{MAX_BODY_LINES}-line note budget"
    end
  end

  def test_name_and_description_caps
    each_doc do |_klass, meta, _body, path|
      assert_operator meta["name"].to_s.length, :<=, MAX_NAME_CHARS, path
      desc = meta["description"].to_s
      refute_empty desc, path
      assert_operator desc.length, :<=, MAX_DESCRIPTION_CHARS, path
    end
  end
end
