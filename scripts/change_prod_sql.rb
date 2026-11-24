# frozen_string_literal: true

require 'digest'

# Classifies prod SQL for the autopilot recovery precondition. A statement is
# non-destructive only when it is on a short allowlist (see `classify`); every
# other statement is destructive, as is any statement whose estimated row count
# passes the threshold. Comments and quoted text are blanked first, so a keyword
# inside a string or a comment neither hides nor fakes a statement. Anything the
# scanner cannot read (an unterminated quote, comment or dollar quote, or a
# non-integer estimate) counts as destructive: this fails closed.
module ChangeProdSql
  DEFAULT_THRESHOLD = 1000
  Statement = Struct.new(:sql_sha256, :kind, :destructive, keyword_init: true)
  Unreadable = Class.new(StandardError)

  # Phrases that contain UPDATE or DELETE without being a statement.
  NOT_A_STATEMENT = /\b(?:do\s+update|for\s+update|on\s+update|on\s+delete)\b/

  module_function

  def destructive?(sql, estimated_rows: nil, threshold: DEFAULT_THRESHOLD)
    return true if over_threshold?(estimated_rows, threshold)

    analyze(sql).any?(&:destructive)
  end

  # One entry per top-level statement, in order. Unreadable SQL is one
  # destructive entry of kind 'unparseable'.
  def analyze(sql)
    split(sql.to_s).map { |text| classify(text) }
  rescue Unreadable
    [ Statement.new(sql_sha256: Digest::SHA256.hexdigest(sql.to_s.b), kind: 'unparseable', destructive: true) ]
  end

  def threshold_for(config, op)
    value = config.dig('change_config', 'operations', op.to_s, 'row_threshold') if config.is_a?(Hash)
    value.is_a?(Integer) && value.positive? ? value : DEFAULT_THRESHOLD
  end

  def over_threshold?(estimated_rows, threshold)
    return false if estimated_rows.nil?
    return true unless estimated_rows.is_a?(Integer) && estimated_rows >= 0

    estimated_rows > threshold
  end

  # Statements on top-level semicolons, each as [original text, blanked text].
  def split(sql)
    blanked = blank(sql)
    parts = []
    start = 0
    blanked.each_char.with_index do |char, i|
      next unless char == ';'

      parts << [ sql[start...i], blanked[start...i] ]
      start = i + 1
    end
    parts << [ sql[start..], blanked[start..] ]
    parts.reject { |_, text| text.strip.empty? }
  end

  # The same length as the input: comments and the inside of quotes become
  # spaces (a quoted span keeps its quotes), so offsets line up.
  def blank(sql)
    out = +''
    i = 0
    while i < sql.length
      i = blank_at(sql, i, out)
    end
    out
  end

  def blank_at(sql, i, out)
    rest = sql[i..]
    if rest.start_with?('--')
      stop = sql.index("\n", i) || sql.length
      out << (' ' * (stop - i))
      stop
    elsif rest.start_with?('/*')
      stop = close_comment(sql, i)
      out << (' ' * (stop - i))
      stop
    elsif (tag = rest[/\A\$[A-Za-z_]*\$/])
      quoted(sql, i, tag, tag, out)
    elsif sql[i] == "'" || sql[i] == '"'
      quoted(sql, i, sql[i], sql[i], out)
    else
      out << sql[i]
      i + 1
    end
  end

  # Nested block comments, as Postgres reads them.
  def close_comment(sql, start)
    depth = 0
    i = start
    while i < sql.length
      pair = sql[i, 2]
      if pair == '/*'
        depth += 1
        i += 2
      elsif pair == '*/'
        depth -= 1
        i += 2
        return i if depth.zero?
      else
        i += 1
      end
    end
    raise Unreadable, 'unterminated comment'
  end

  def quoted(sql, start, open, close, out)
    i = start + open.length
    while i < sql.length
      if sql[i, close.length] == close
        # A doubled quote is an escaped quote, not the end.
        if close.length == 1 && sql[i + 1] == close
          i += 2
          next
        end
        stop = i + close.length
        out << open << (' ' * (stop - start - open.length - close.length)) << close
        return stop
      end
      i += 1
    end
    raise Unreadable, 'unterminated quote'
  end

  # Parenthesized text collapsed to "()", so a WHERE inside a subquery does not
  # count as the statement's own.
  def top_level(text)
    depth = 0
    kept = +''
    text.each_char do |char|
      depth -= 1 if char == ')'
      raise Unreadable, 'unbalanced parenthesis' if depth.negative?

      kept << char if depth.zero?
      depth += 1 if char == '('
    end
    raise Unreadable, 'unbalanced parenthesis' unless depth.zero?

    kept
  end

  # Anything outside this list is destructive: the cost of a false positive is
  # one extra verified snapshot, the cost of a miss is lost data.
  #
  #   SELECT (not SELECT INTO), including a WITH with no data-changing keyword
  #   SHOW, EXPLAIN without ANALYZE
  #   INSERT ... VALUES with no ON CONFLICT ... DO UPDATE
  #   UPDATE or DELETE with a top-level WHERE (still subject to the row threshold)
  #   BEGIN, COMMIT, ROLLBACK, SET (but not SET ROLE or SESSION AUTHORIZATION)
  #
  # DO blocks, CALL, COPY, ALTER, GRANT, CREATE, MERGE, VACUUM and every unknown
  # verb are destructive, as is a WITH holding DML in a CTE body.
  DATA_CHANGING = /\b(?:delete|update|insert|merge|truncate|drop)\b/
  CONTROL = %w[begin commit rollback].freeze

  def classify(pair)
    original, blanked = pair
    raw = top_level(blanked).downcase
    text = raw.gsub(NOT_A_STATEMENT, ' ')
    full = blanked.downcase.gsub(NOT_A_STATEMENT, ' ')
    verb = text.split.first.to_s[/\A[a-z_]+/] || 'other'
    kind = verb == 'with' ? (full.match?(DATA_CHANGING) ? 'with_dml' : 'with') : verb
    Statement.new(sql_sha256: Digest::SHA256.hexdigest(original.strip.b), kind: kind, destructive: !allowed?(kind, raw, text, blanked.downcase))
  end

  def allowed?(kind, raw, text, full)
    case kind
    when 'select', 'show', 'with' then kind != 'select' || !text.match?(/\binto\b/)
    when 'explain' then !full.match?(/\banaly[sz]e\b/)
    when 'insert' then text.match?(/\bvalues\b/) && !text.match?(/\bselect\b/) && !raw.match?(/\bon\s+conflict\b.*\bdo\s+update\b/m)
    when 'update', 'delete' then text.match?(/\bwhere\b/)
    when 'set' then !text.match?(/\b(?:role|authorization)\b/)
    else CONTROL.include?(kind)
    end
  end
end
