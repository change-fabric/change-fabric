# frozen_string_literal: true

require 'cgi'

# raw.xml (pdftohtml -xml -i) to the normalized report pieces. Text fragments
# are grouped into visual lines by position, list markers (which the export
# draws as separate elements) become item starts, and the report is split by
# the skeleton headings. Citations pair two ways: ChatGPT's `【ref†Lx-Ly】`
# tokens pair with the Sources entry carrying the same ref, and `[n]` footnote
# markers pair with the Sources entry numbered n. Anything ambiguous fails
# closed: the finding is kept, source_ids stay empty, and a diagnostic says why.
module DeepResearchParse
  HEADINGS = %w[summary findings sources unverified contested].freeze
  HEADING_RE = /\A#*\s*(#{HEADINGS.join('|')})\s*:?\z/i
  ITEM_RE = /\A\s*(?:(\d+)[.)]|[-•*])\s+(.*)\z/m
  SOURCE_RE = /\A\s*\[?(\d+)[.\]):]\s*(.*)\z/m
  MARKER_RE = /\[(\d+(?:\s*[,;]\s*\d+)*)\]/
  TOKEN_RE = /【\s*(\d+)\s*†\s*(L\d+(?:\s*-\s*L?\d+)?)\s*】/
  LIST_MARKER_RE = /\A\s*(?:(\d+)\.|([•*-]))\s*\z/
  # A standalone empty-section reply. Anything that carries a citation, or
  # makes a claim beyond "none", is a finding.
  NONE_RE = /\A\s*(none\.?|none (found|identified|noted)\b.*|(we )?(found |identified )?no (direct )?(contradictions?|conflicts?|disagreements?)\b.*)\z/i
  QUOTE_RE = /["“](.+?)["”]/
  URL_RE = %r{https?://[^\s<>"”【]+}
  LINE_TOLERANCE = 6

  Line = Struct.new(:text, :links, :page, :marker)

  module_function

  # Visual lines in reading order. Fragments whose tops are within a few
  # pixels share a line (inline code and bold runs sit slightly off); a
  # leading bare list marker becomes the line's marker.
  def lines(xml)
    xml.scan(%r{<page\b([^>]*)>(.*?)</page>}m).flat_map do |attrs, body|
      page = attrs[/number="(\d+)"/, 1].to_i
      height = attrs[/height="(\d+)"/, 1].to_f
      frags = body.scan(%r{<text\b([^>]*)>(.*?)</text>}m).map { |a, inner| fragment(a, inner) }
      cluster(frags).filter_map { |group| line(group, page, height) }
    end
  end

  def fragment(attrs, inner)
    links = inner.scan(/<a\b[^>]*href="([^"]*)"/).flatten.map { |h| CGI.unescapeHTML(h) }.grep(%r{\Ahttps?://}i)
    { top: attrs[/top="(-?\d+)"/, 1].to_i, left: attrs[/left="(-?\d+)"/, 1].to_i,
      raw: CGI.unescapeHTML(inner.gsub(/<[^>]+>/, '')), links: links }
  end

  def cluster(frags)
    groups = []
    frags.sort_by { |f| [ f[:top], f[:left] ] }.each do |f|
      if groups.any? && f[:top] - groups.last.first[:top] <= LINE_TOLERANCE then groups.last << f
      else groups << [ f ]
      end
    end
    groups.map { |g| g.sort_by { |f| f[:left] } }
  end

  def line(group, page, height)
    marker = nil
    if group.size > 1 && (m = group.first[:raw].match(LIST_MARKER_RE))
      marker = m[1] ? m[1].to_i : :bullet
      group = group.drop(1)
    end
    text = group.map { |f| f[:raw] }.join.gsub(/\s+/, ' ').strip
    return if group.size == 1 && text.match?(/\A\d+\z/) && group.first[:top] > height * 0.9

    Line.new(text, group.flat_map { |f| f[:links] }, page, marker)
  end

  def text(xml) = lines(xml).map(&:text).join("\n")

  # Visible text plus every decoded link target, for the secret scan.
  def scannable_text(xml)
    targets = xml.scan(/href="([^"]*)"/).flatten.map { |h| CGI.unescapeHTML(h) }
    [ text(xml), *targets ].join("\n")
  end

  def page_one_text(xml) = lines(xml).select { |l| l.page == 1 }.map(&:text).join("\n")

  # Joins wrapped lines. A hyphen or a URL cut at a slash rejoins with no space.
  def join(texts)
    texts.reduce('') do |acc, t|
      glue = acc.empty? || acc.match?(%r{\w-\z|https?://(?:\S*/)?\z}) ? '' : ' '
      "#{acc}#{glue}#{t}"
    end.gsub(/\s+/, ' ').strip
  end

  def normalize_tokens(text)
    text.gsub(/\s+(?=【)/, '').gsub(TOKEN_RE) { "【#{Regexp.last_match(1)}†#{Regexp.last_match(2).delete(' ')}】" }
  end

  def parse(xml)
    diagnostics = []
    all_lines = lines(xml)
    sections = split(all_lines, diagnostics)
    sources, unlinked, dup, urlless = sources(sections['sources'], diagnostics)
    findings = items(sections['findings'], diagnostics, ordered: true)
    extras = %w[unverified contested].flat_map do |name|
      items(sections[name], diagnostics, ordered: false).each { |i| i[:status] = name }
                                                        .reject { |i| none_item?(i, name, diagnostics) }
    end
    all = findings.each { |i| i[:status] = 'unverified' } + extras
    known = { dup: dup, urlless: urlless, conflict: {} }
    result = build(all, sources, known, diagnostics)
    summary = normalize_tokens(join(sections['summary'].map(&:text)))
    result[:citations].concat(cite(summary, 'summary', 'summary', result[:by_ref], result[:by_number], diagnostics, known))
    result.except(:by_ref, :by_number).merge(
      summary: summary, diagnostics: diagnostics,
      link_annotations: annotation_level(all_lines.any? { |l| l.links.any? }, unlinked)
    )
  end

  def none_item?(item, name, diagnostics)
    return false unless item[:text].match?(NONE_RE) && !item[:text].match?(TOKEN_RE) && !item[:text].match?(MARKER_RE)

    diagnostics << "#{name} section reports none"
    true
  end

  def split(all, diagnostics)
    sections = HEADINGS.to_h { |h| [ h, nil ] }
    current = nil
    all.each do |line|
      if (m = line.text.match(HEADING_RE))
        name = m[1].downcase
        diagnostics << "duplicate heading: #{name}" if sections[name]
        sections[name] ||= []
        current = sections[name]
      elsif current && !(line.text.empty? && line.marker.nil?)
        current << line
      end
    end
    HEADINGS.each { |h| diagnostics << "missing heading: #{h}" if sections[h].nil? }
    sections.transform_values { |v| v || [] }
  end

  # Item boundaries: marked lines when the section has any, else lines that
  # open with a numeral or bullet. Following lines are a wrapped continuation.
  def raw_items(lines, diagnostics, ordered:)
    marked = lines.any?(&:marker)
    out = []
    lines.each do |line|
      _number, rest = start_of_item(line, marked)
      if rest
        out << { parts: [ rest ], links: line.links.dup }
      elsif out.empty?
        diagnostics << 'ambiguous finding boundary' if ordered
        out << { parts: [ line.text ], links: line.links.dup }
      else
        out.last[:parts] << line.text
        out.last[:links].concat(line.links)
      end
    end
    out
  end

  def start_of_item(line, marked)
    return [ line.marker.is_a?(Integer) ? line.marker : 0, line.text ] if line.marker
    return nil if marked

    (m = line.text.match(ITEM_RE)) ? [ m[1].to_i, m[2] ] : nil
  end

  def items(lines, diagnostics, ordered:)
    raw_items(lines, diagnostics, ordered: ordered).map do |i|
      { text: normalize_tokens(join(i[:parts])), links: i[:links] }
    end
  end

  # Source entries by number. A number that appears twice is dropped entirely
  # (ambiguous) and recorded in the returned duplicate set.
  def sources(lines, diagnostics)
    entries = source_entries(lines)
    dup = entries.map { |e| e[:number] }.tally.select { |_n, c| c > 1 }.keys
    dup.each { |n| diagnostics << "duplicate source number: #{n}" }
    urlless = {}
    kept = entries.reject { |e| dup.include?(e[:number]) }.filter_map do |e|
      url = e[:links].first || source_url(e[:text])
      unless url
        diagnostics << "source #{e[:number]} has no URL"
        e[:text].scan(TOKEN_RE) { |ref, _| urlless[ref] = e[:number] }
        next
      end

      { number: e[:number], url: url, title: title_of(e[:text], url),
        refs: e[:text].scan(TOKEN_RE).map { |ref, _| ref } }
    end
    [ kept, entries.empty? || entries.any? { |e| e[:links].empty? }, dup, urlless ]
  end

  # The URL after a `URL:` label wins over any other link in the entry text.
  def source_url(text)
    (text[/URL:\s*(#{URL_RE})/, 1] || text[URL_RE])&.sub(/[.,;)]+\z/, '')
  end

  def source_entries(lines)
    marked = lines.any?(&:marker)
    entries = []
    lines.each do |line|
      number, rest = source_start(line, marked)
      if number && (!rest.empty? || marked)
        entries << { number: number, parts: [ rest ], links: line.links.dup }
      elsif entries.any?
        entries.last[:parts] << line.text
        entries.last[:links].concat(line.links)
      end
    end
    entries.each { |e| e[:text] = normalize_tokens(join(e[:parts])) }
  end

  def source_start(line, marked)
    return [ line.marker.is_a?(Integer) ? line.marker : 0, line.text ] if line.marker
    return nil if marked

    (m = line.text.match(SOURCE_RE)) ? [ m[1].to_i, m[2] ] : nil
  end

  def title_of(text, url)
    clean = text.gsub(TOKEN_RE, '').sub(/\s*URL:\s*#{Regexp.escape(url)}/, '').sub(url, '')
    title = clean[0, colon_outside_quotes(clean) || clean.length]
    title = title.gsub(/\A[\s\-\u2013\u2014:|.,]+|[\s\-\u2013\u2014:|.,]+\z/, '')[0, 200]
    title.empty? ? nil : title
  end

  # Index of the first ": " that is not inside curly double quotes.
  def colon_outside_quotes(text)
    depth = 0
    text.each_char.with_index do |c, i|
      depth += 1 if c == '“'
      depth -= 1 if c == '”'
      return i if c == ':' && depth <= 0 && text[i + 1] == ' '
    end
    nil
  end

  def build(all, sources, known, diagnostics)
    out_sources = sources.map { |s| { 'id' => "S#{s[:number]}", 'url' => s[:url], 'title' => s[:title] } }
    by_number = sources.to_h { |s| [ s[:number], "S#{s[:number]}" ] }
    by_ref = {}
    ref_sources = Hash.new { |h, k| h[k] = [] }
    sources.each { |s| s[:refs].each { |r| ref_sources[r] << s } }
    ref_sources.each do |ref, owners|
      if owners.map { |o| o[:url] }.uniq.size > 1
        known[:conflict][ref] = owners.map { |o| o[:number] }
      else
        by_ref[ref] = "S#{owners.first[:number]}"
      end
    end
    findings = []
    citations = []
    all.each_with_index do |item, i|
      id = "F#{i + 1}"
      before = diagnostics.size
      cites = cite(item[:text], id, 'claim', by_ref, by_number, diagnostics, known)
      unresolved = diagnostics.size - before
      ids = cites.map { |c| c['source_id'] }
      item[:links].each do |href|
        source = out_sources.find { |s| s['url'] == href } || add_chip(out_sources, href)
        next if ids.include?(source['id'])

        ids << source['id']
        cites << { 'finding_id' => id, 'source_id' => source['id'], 'span' => nil }
      end
      citations.concat(cites)
      findings << { 'id' => id, 'claim' => item[:text], 'status' => item[:status] == 'contested' ? 'contested' : 'unverified',
                    'source_ids' => ids.uniq, 'quote' => item[:text][QUOTE_RE, 1],
                    'unresolved_citations' => unresolved }
    end
    { findings: findings, sources: out_sources, citations: citations, by_ref: by_ref, by_number: by_number }
  end

  # Citations for one text: ref tokens by ref id, `[n]` markers by number. A
  # span is set only when the marker occurs once in the text.
  def cite(text, finding_id, basis, by_ref, by_number, diagnostics, known = { dup: [], urlless: {}, conflict: {} })
    out = []
    text.scan(TOKEN_RE) do |ref, _|
      m = Regexp.last_match
      sid = by_ref[ref]
      unless sid
        diagnostics << ref_diagnostic(finding_id, ref, known)
        next
      end

      out << citation(finding_id, sid, basis, text, m)
    end
    text.scan(MARKER_RE) do |(nums)|
      m = Regexp.last_match
      nums.split(/[,;]/).map { |n| n.strip.to_i }.each do |n|
        sid = by_number[n]
        unless sid
          diagnostics << "#{finding_id}: footnote #{n} has no source#{' (ambiguous number)' if known[:dup].include?(n)}"
          next
        end

        out << citation(finding_id, sid, basis, text, m)
      end
    end
    out.uniq
  end

  def ref_diagnostic(finding_id, ref, known)
    return "#{finding_id}: ref #{ref} maps to conflicting sources #{known[:conflict][ref].join(', ')}; left unresolved" if known[:conflict][ref]

    number = known[:urlless][ref]
    return "#{finding_id}: ref #{ref} has no source entry" unless number

    "#{finding_id}: ref #{ref} belongs to source #{number}, which has no URL"
  end

  def citation(finding_id, source_id, basis, text, match)
    unique = text.scan(match[0]).size == 1
    span = unique ? { 'basis' => basis, 'start' => match.begin(0), 'end' => match.end(0) } : nil
    { 'finding_id' => finding_id, 'source_id' => source_id, 'span' => span }
  end

  # An inline link chip names a source that is not in the Sources list; give it
  # the next free id.
  def add_chip(out_sources, href)
    next_n = (out_sources.filter_map { |s| s['id'][1..].to_i }.max || 0) + 1
    source = { 'id' => "S#{next_n}", 'url' => href, 'title' => nil }
    out_sources << source
    source
  end

  # none: no http link annotation anywhere; full: every Sources entry carried
  # one; partial: some, but not every, entry did.
  def annotation_level(any_link, unlinked)
    return 'none' unless any_link

    unlinked ? 'partial' : 'full'
  end
end
