# frozen_string_literal: true

require_relative 'epic_store'

# The phase-level dependency graph of an epic. Nodes are `<plan_id>#Phase N`.
# Phases inside one plan are ordered implicitly (Phase N before the next one);
# declared edges add the cross-plan order. Ordering is a hand-written Kahn's
# algorithm that pops the whole zero in-degree frontier as one layer, so nodes
# in a layer can land in parallel. Nodes left over have a cycle among them.
module EpicGraph
  NODE = /\A(?<plan>[^#\s]+)#Phase (?<phase>\d+)\z/

  Order = Data.define(:layers, :cycle)

  def self.node_id(plan_id, phase) = "#{plan_id}#Phase #{phase}"

  # `P2#Phase 01` names the same node as `P2#Phase 1`; epic_check accepts
  # both, so the graph must too or the edge is silently dropped.
  def self.canonical(ref)
    match = NODE.match(ref.to_s)
    match ? node_id(match[:plan], match[:phase].to_i) : ref.to_s
  end

  # Natural order: plan id, then phase number, so Phase 10 follows Phase 9.
  def self.sort_key(node)
    match = NODE.match(node)
    match ? [ match[:plan], match[:phase].to_i ] : [ node, 0 ]
  end

  # Builds from an epic. Edges naming a node that does not exist are dropped
  # here; epic_check reports them.
  def self.build(epic)
    nodes = []
    edges = []
    epic.plans.each do |plan|
      numbers = (EpicStore.phases_for(epic, plan) || []).map(&:first).uniq.sort
      ids = numbers.map { |number| node_id(plan['id'], number) }
      nodes.concat(ids)
      edges.concat(ids.each_cons(2).to_a)
    end
    known = nodes.to_h { |node| [ node, true ] }
    epic.edges.each do |edge|
      pair = [ canonical(edge['from']), canonical(edge['to']) ]
      edges << pair if pair.all? { |node| known[node] }
    end
    Graph.new(nodes, edges)
  end

  # A directed graph over string node ids.
  class Graph
    attr_reader :nodes

    def initialize(nodes, edges)
      @nodes = nodes.uniq.sort_by { |node| EpicGraph.sort_key(node) }
      @successors = @nodes.to_h { |node| [ node, [] ] }
      edges.uniq.each { |from, to| @successors[from] << to if @successors.key?(from) && @successors.key?(to) }
    end

    def successors(node) = @successors.fetch(node, [])

    def order
      indegree = @nodes.to_h { |node| [ node, 0 ] }
      @successors.each_value { |tos| tos.each { |to| indegree[to] += 1 } }
      layers = []
      frontier = sorted(indegree.select { |_, count| count.zero? }.keys)
      until frontier.empty?
        layers << frontier
        frontier.each { |node| indegree.delete(node) }
        released = frontier.flat_map { |node| successors(node) }.select { |to| (indegree[to] -= 1).zero? }
        frontier = sorted(released.uniq)
      end
      Order.new(layers:, cycle: sorted(indegree.keys))
    end

    # Every node reachable from `node`, excluding itself: the affected set.
    def downstream(node)
      seen = {}
      stack = successors(node).dup
      until stack.empty?
        current = stack.pop
        next if seen[current]

        seen[current] = true
        stack.concat(successors(current))
      end
      sorted(seen.keys - [ node ])
    end

    private

    def sorted(list) = list.sort_by { |node| EpicGraph.sort_key(node) }
  end
end
