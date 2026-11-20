#!/usr/bin/env ruby
# frozen_string_literal: true

# Structural lint for the resource gate in a cf:plan workflow.js.
#
#   ruby scripts/resource_gate_lint.rb FILE...     # exit 1 on any violation
#
# Rules (a gate is a statement that starts with `await gate(`, optionally
# `const x = await gate(`):
#
#   phase0    the first phase() call has a literal title, and the statement
#             right after it is a gate;
#   loop      the first statement after `phase(spec.title)` inside the
#             `for (... of PHASES)` body is a gate;
#   parallel  every statement containing `parallel(` is directly preceded by a
#             gate. One guard `if (!g || !g.ok) ...` may sit between them.
#
# A gate does not count when it sits after a return, throw, break or continue
# in the same block, inside `if (false)`, in a comment or in a string, or when
# any other statement comes between it and its anchor. The checker has no JS
# engine: it blanks comments and string bodies, splits the text into
# statements by bracket depth, and recurses into control-flow blocks.
module ResourceGateLint
  Stmt = Struct.new(:head, :blocks, :dead)

  GATE = /\A(?:(?:const|let|var)\s+\w+\s*=\s*)?await\s+gate\(/
  GUARD = /\Aif\s*\(\s*!\s*(\w+)\s*(?:\|\|\s*!\s*\1\.ok|\.ok)\s*\)/
  TERMINATOR = /\A(?:return|throw|break|continue)\b/
  DEAD_IF = /\Aif\s*\(\s*(?:false|0)\s*\)/
  PHASE_LITERAL = /\Aphase\(\s*["'`]/
  LOOP_PHASE = /\Aphase\(\s*\w+\.title\s*\)/
  PHASES_LOOP = /\Afor\s*\(\s*(?:const|let)\s+\w+\s+of\s+PHASES\s*\)/
  CONTINUES = /\A(?:[.+?:,)]|&&|\|\||else\b|catch\b|finally\b)/
  OPEN_ENDED = /(?:[=+\-*\/&|?:,(]|=>)\z/
  CONTROL_HEAD = /\A(?:if|for|while)\s*\(/

  module_function

  # Returns an array of violation strings; empty means the script is clean.
  def check(source)
    stmts, = parse_list(sanitize(source), 0, false)
    flat = []
    walk(stmts, flat)
    check_phase0(flat) + check_loop(stmts) + check_parallel(flat)
  end

  def check_phase0(flat)
    list, idx, = flat.find { |_, i, l| l[i].head.start_with?('phase(') }
    return [ 'phase0: no phase() call before the PHASES loop' ] unless list
    return [ 'phase0: the first phase() call needs a literal title (Resource floors)' ] unless list[idx].head.match?(PHASE_LITERAL)

    gate_follows?(list, idx) ? [] : [ 'phase0: the statement after the first phase() call must be `await gate(`' ]
  end

  def check_loop(stmts)
    body = loop_body(stmts)
    return [ 'loop: no `for (... of PHASES)` loop with phase(spec.title)' ] unless body

    list, dead = body
    idx = list.index { |s| s.head.match?(LOOP_PHASE) }
    return [ 'loop: no phase(spec.title) call in the PHASES loop' ] unless idx

    gate_follows?(list, idx) && !dead ? [] : [ 'loop: the first statement after phase(spec.title) must be `await gate(`' ]
  end

  def check_parallel(flat)
    flat.filter_map do |list, idx, _|
      next unless list[idx].head.match?(/\bparallel\(/)

      'parallel: every parallel( must be directly preceded by `await gate(`' unless gate_precedes?(list, idx)
    end
  end

  def loop_body(stmts)
    stmts.each do |s|
      return [ s.blocks.first, s.dead ] if s.head.match?(PHASES_LOOP) && s.blocks.first

      s.blocks.each { |b| (found = loop_body(b)) && (return found) }
    end
    nil
  end

  # True when list[idx + 1] is a live gate: not dead, nothing terminating before.
  def gate_follows?(list, idx)
    gate = list[idx + 1]
    gate && gate.head.match?(GATE) && live?(list, idx + 1)
  end

  def gate_precedes?(list, idx)
    prev = idx - 1
    prev -= 1 if prev.positive? && list[prev].head.match?(GUARD)
    prev >= 0 && list[prev].head.match?(GATE) && live?(list, prev)
  end

  def live?(list, idx)
    return false if list[idx].dead

    list[0...idx].none? { |s| s.head.match?(TERMINATOR) }
  end

  # Document order, one [list, index, list] row per statement.
  def walk(stmts, out)
    stmts.each_index do |i|
      out << [ stmts, i, stmts ]
      stmts[i].blocks.each { |b| walk(b, out) }
    end
  end

  # Blank comments and string bodies, keeping length and newlines.
  def sanitize(src)
    out = +''
    i = 0
    while i < src.length
      c = src[i]
      if src[i, 2] == '//'
        i += 1 until i >= src.length || src[i] == "\n"
      elsif src[i, 2] == '/*'
        j = src.index('*/', i + 2) || (src.length - 2)
        out << src[i...(j + 2)].gsub(/[^\n]/, ' ')
        i = j + 2
      elsif [ '"', "'", '`' ].include?(c)
        j = string_end(src, i)
        out << c << src[(i + 1)...j].gsub(/[^\n]/, ' ') << c
        i = j + 1
      else
        out << c
        i += 1
      end
    end
    out
  end

  def string_end(src, start)
    quote = src[start]
    i = start + 1
    i += (src[i] == '\\' ? 2 : 1) while i < src.length && src[i] != quote && (quote == '`' || src[i] != "\n")
    i
  end

  # Parses statements until an unmatched `}` (when nested) or the end.
  def parse_list(text, pos, nested, dead = false)
    stmts = []
    loop do
      pos += 1 while pos < text.length && (text[pos] =~ /\s/ || text[pos] == ';')
      break if pos >= text.length || text[pos] == '}'

      stmt, pos = parse_stmt(text, pos, dead)
      stmts << stmt
    end
    [ stmts, nested && text[pos] == '}' ? pos + 1 : pos ]
  end

  def parse_stmt(text, pos, dead)
    stmt = Stmt.new(+'', [], dead)
    depth = 0
    while pos < text.length
      c = text[pos]
      if c == '}' && depth.zero?
        break
      elsif c == '{' && depth.zero? && block_brace?(stmt.head)
        pos = parse_block(text, pos, stmt)
        break unless continues?(text, pos)
      elsif c == "\n" && depth.zero? && !continuation?(text, pos, stmt.head)
        break
      elsif c == ';' && depth.zero?
        break
      else
        depth += 1 if '([{'.include?(c)
        depth -= 1 if ')]}'.include?(c)
        stmt.head << c
        pos += 1
      end
    end
    stmt.head = stmt.head.strip.gsub(/\s+/, ' ')
    [ stmt, pos ]
  end

  def parse_block(text, pos, stmt)
    stmt.head << ' {} '
    block, pos = parse_list(text, pos + 1, true, stmt.dead || stmt.head.match?(DEAD_IF))
    stmt.blocks << block
    pos
  end

  def block_brace?(head)
    h = head.rstrip
    h.empty? || h.end_with?(')', '=>') || h.match?(/(?:\A|\s)(?:else|try|finally|do)\z/)
  end

  def continues?(text, pos)
    text[pos..].to_s.match?(/\A[ \t]*(?:else|catch|finally)\b/)
  end

  def continuation?(text, pos, head)
    rest = text[(pos + 1)..].to_s[/\A\s*(.{0,2})/m, 1].to_s
    h = head.rstrip
    rest.match?(CONTINUES) || h.match?(OPEN_ENDED) || braceless?(h)
  end

  # `if (...)` or `for (...)` whose parenthesis closes at the end of the head.
  def braceless?(head)
    return false unless head.match?(CONTROL_HEAD)

    depth = 0
    head.each_char.with_index do |c, i|
      depth += 1 if c == '('
      depth -= 1 if c == ')'
      return i == head.length - 1 if depth.zero? && c == ')'
    end
    false
  end

  def self.run(paths, out: $stdout)
    bad = paths.flat_map do |path|
      check(File.read(path)).map { |v| "#{path}: #{v}" }
    end
    bad.each { |line| out.puts(line) }
    out.puts('resource gate lint: ok') if bad.empty?
    bad.empty? ? 0 : 1
  end
end

exit(ResourceGateLint.run(ARGV)) if $PROGRAM_NAME == __FILE__
