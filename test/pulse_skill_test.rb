# frozen_string_literal: true

require "minitest/autorun"

# Drift check only: the behavioral enforcer of the integrity lens is the C5
# matrix in pulse_integrity_test.rb. This fails when the brief stops naming
# what the code enforces.
class PulseSkillTest < Minitest::Test
  BRIEF = File.read(File.expand_path("../skills/pulse/SKILL.md", __dir__))

  def test_names_the_four_lenses_and_the_output_contract
    %w[accel integrity stall scope].each { |lens| assert_match(/^- #{lens}:/, BRIEF) }
    [ "No evidence, no finding", "serves", "Never stop at all-green", "[cf] pulse" ].each { |text| assert_includes BRIEF, text }
  end

  def test_integrity_lens_names_every_c5_check
    [ "vacuous pass", "skipped counted as", "narrowed run", "bound to the head SHA", "a missing denominator" ].each do |text|
      assert_includes BRIEF.tr("\n", " ").squeeze(" "), text
    end
  end

  def test_names_the_coordinator_sequence_in_order
    steps = [ "pulse_scope.rb", "pulse_precheck.rb", "pulse_integrity.rb", "pulse_store.rb reserve", "pulse_store.rb append", "pulse_watch.rb" ]
    positions = steps.map { |step| BRIEF.index(step) }
    refute_includes positions, nil
    assert_equal positions.sort, positions
  end

  def test_states_hard_limits_roles_and_the_background_heuristic
    [ "{{model:worker}}", "{{model:critic}}", "{{model:classifier}}", "escape-hatch", "1 hour", "/cf:pulse off" ].each do |text|
      assert_includes BRIEF, text
    end
  end

  def test_names_only_scripts_that_exist
    named = BRIEF.scan(/\b(pulse_\w+)\.rb/).flatten.uniq
    missing = named.reject { |name| File.file?(File.expand_path("../scripts/#{name}.rb", __dir__)) }
    assert_empty missing
  end
end
