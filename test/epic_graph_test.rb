# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/epic_graph"

class EpicGraphTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/epic", __dir__)
  PLANS = File.join(FIXTURES, "clean/plans")

  def clean_graph = EpicGraph.build(EpicStore.load(File.join(FIXTURES, "clean/epic.md"), plans_root: PLANS))

  def test_clean_fixture_orders_into_expected_layers
    order = clean_graph.order

    assert_empty order.cycle
    assert_equal [
      [ "P1#Phase 1", "P4#Phase 1" ],
      [ "P1#Phase 2", "P2#Phase 1" ],
      [ "P2#Phase 2" ],
      [ "P3#Phase 1" ],
      [ "P3#Phase 2" ]
    ], order.layers
  end

  def test_build_adds_implicit_intra_plan_edges
    graph = clean_graph

    assert_equal [ "P1#Phase 2", "P2#Phase 1" ], graph.successors("P1#Phase 1").sort
    assert_equal [ "P3#Phase 2" ], graph.successors("P3#Phase 1")
  end

  def test_cycle_reports_leftover_nodes
    graph = EpicGraph::Graph.new(%w[a b c d], [ %w[a b], %w[b c], %w[c b], %w[c d] ])
    order = graph.order

    assert_equal [ [ "a" ] ], order.layers
    assert_equal %w[b c d], order.cycle
  end

  def test_layers_sort_phase_numbers_naturally
    nodes = [ "P1#Phase 10", "P1#Phase 9", "P0#Phase 2" ]

    assert_equal [ [ "P0#Phase 2", "P1#Phase 9", "P1#Phase 10" ] ], EpicGraph::Graph.new(nodes, []).order.layers
  end

  def test_downstream_is_the_transitive_affected_set
    graph = clean_graph

    assert_equal [ "P1#Phase 2", "P2#Phase 1", "P2#Phase 2", "P3#Phase 1", "P3#Phase 2" ], graph.downstream("P1#Phase 1")
    assert_empty graph.downstream("P3#Phase 2")
    assert_empty graph.downstream("P4#Phase 1")
  end

  def test_downstream_terminates_on_a_cycle
    graph = EpicGraph::Graph.new(%w[a b], [ %w[a b], %w[b a] ])

    assert_equal %w[b], graph.downstream("a")
  end

  def test_edges_to_unknown_nodes_are_ignored_by_the_graph
    graph = EpicGraph::Graph.new(%w[a], [ %w[a ghost] ])

    assert_equal [ [ "a" ] ], graph.order.layers
  end

  def test_no_tsort_anywhere_in_epic_scripts
    Dir.glob(File.join(SKILL_SCRIPTS, "epic_*.rb")).each do |path|
      refute_match(/tsort/i, File.read(path), "#{File.basename(path)} must use the hand-written Kahn sort")
    end
  end
end
