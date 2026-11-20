# frozen_string_literal: true

require 'cgi'

# raw.xml (pdftohtml -xml -i) to the normalized report pieces. The parser
# splits sections by the skeleton headings, then pairs each footnote marker
# with the Sources entry carrying that number. Anything ambiguous fails closed:
# the finding is kept, source_ids stay empty, and a diagnostic says why.
module DeepResearchParse
  HEADINGS = %w[summary findings sources unverified contested].freeze
  HEADING_RE = /\A#*\s*(#{HEADINGS.join('|')})\s*:?\z/i
  ITEM_RE = /\A\s*(?:(\d+)[.)]|[-•*])\s+(.*)\z/m
  SOURCE_RE = /\A\s*\[?(\d+)[.\]):]\s*(.*)\z/m
  MARKER_RE = /\[(\d+(?:\s*[,;]\s*\d+)*)\]/
  QUOTE_RE = /["“](.+?)["”]/
  URL_RE = %r{https?://[^\s<>"”]+}

  Line = Struct.new(:text, :links, :page)

  module_function

  # Ordered lines with the http(s) hrefs found inside each one.
  def lines(xml)
    xml.scan(%r{<page\b[^>]*number="(\d+)"[^>]*>(.*?)</page>}m).flat_map do |page, body|
      body.scan(%r{<text\b[^>]*>(.*?)</text>}m).map do |(inner)|
        links = inner.scan(/<a\b[^>]*href="([^"]*)"/).flatten.map { |h| CGI.unescapeHTML(h) }.grep(%r{\Ahttps?://}i)
        Line.new(CGI.unescapeHTML(inner.gsub(/<[^>]+>/, '')).strip, links, page.to_i)
      end
    end
  end

  def text(xml) = lines(xml).map(&:text).join("\n")

  def page_one_text(xml) = lines(xml).select { |l| l.page == 1 }.map(&:text).join("\n")

  def parse(xml)
    diagnostics = []
    sections = split(all_lines = lines(xml), diagnostics)
    sources, unlinked, dup = sources(sections['sources'], diagnostics)
    findings = items(sections['findings'], diagnostics, ordered: true)
    extras = %w[unverified contested].flat_map do |name|
      items(sections[name], diagnostics, ordered: false).each { |i| i[:status] = name }
    end
    all = findings.each { |i| i[:status] = 'unverified' } + extras
    by_number = sources.to_h { |s| [ s[:number], s ] }
    result = build(all, by_number, dup, sources, diagnostics)
    summary = sections['summary'].map(&:text).reject(&:empty?).join(' ')
    result[:citations].concat(summary_citations(summary, by_number))
    result.merge(summary: summary, diagnostics: diagnostics,
                 link_annotations: annotation_level(all_lines.any? { |l| l.links.any? }, unlinked))
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
      elsif current && !line.text.empty?
        current << line
      end
    end
    HEADINGS.each { |h| diagnostics << "missing heading: #{h}" if sections[h].nil? }
    sections.transform_values { |v| v || [] }
  end

  # Source entries by number. A number that appears twice is dropped entirely
  # (ambiguous) and recorded in the returned duplicate set.
  def sources(lines, diagnostics)
    entries = []
    lines.each do |line|
      if (m = line.text.match(SOURCE_RE)) && (entries.empty? || m[2].match?(/\S/))
        entries << { number: m[1].to_i, text: m[2], links: line.links.dup }
      elsif entries.any?
        entries.last[:text] = "#{entries.last[:text]} #{line.text}"
        entries.last[:links].concat(line.links)
      end
    end
    counts = entries.map { |e| e[:number] }.tally
    dup = counts.select { |_n, c| c > 1 }.keys
    dup.each { |n| diagnostics << "duplicate source number: #{n}" }
    kept = entries.reject { |e| dup.include?(e[:number]) }.filter_map do |e|
      url = e[:links].first || e[:text][URL_RE]&.sub(/[.,;)]+\z/, '')
      next diagnostics << "source #{e[:number]} has no URL" unless url

      title = e[:text].sub(url, '').gsub(/[\s\-–—:|()<>]+\z|\A[\s\-–—:|()<>]+/, '').strip
      { number: e[:number], url: url, title: title.empty? ? nil : title, linked: !e[:links].empty? }
    end
    [ kept, entries.any? { |e| e[:links].empty? } || entries.empty?, dup ]
  end

  # Items start at a numbered or bulleted line; the following lines are a
  # wrapped continuation. Text before the first item, or a section with no item
  # starts at all, is one ambiguous item.
  def items(lines, diagnostics, ordered:)
    out = []
    lines.each do |line|
      if (m = line.text.match(ITEM_RE))
        out << { text: m[2], links: line.links.dup }
      elsif out.empty?
        diagnostics << 'ambiguous finding boundary' if ordered
        out << { text: line.text, links: line.links.dup }
      else
        out.last[:text] = "#{out.last[:text]} #{line.text}"
        out.last[:links].concat(line.links)
      end
    end
    out
  end

  def build(all, by_number, dup, sources, diagnostics)
    out_sources = sources.map { |s| { 'id' => "S#{s[:number]}", 'url' => s[:url], 'title' => s[:title] } }
    findings = []
    citations = []
    all.each_with_index do |item, i|
      id = "F#{i + 1}"
      ids = []
      item[:text].scan(MARKER_RE) do |(nums)|
        span_start = Regexp.last_match.begin(0)
        marker = Regexp.last_match[0]
        nums.split(/[,;]/).map { |n| n.strip.to_i }.each do |n|
          if by_number[n] then ids << "S#{n}"
          else diagnostics << "#{id}: footnote #{n} has no source#{' (ambiguous number)' if dup.include?(n)}"
          end
          next unless by_number[n]

          unique = item[:text].scan(marker).size == 1
          span = unique ? { 'basis' => 'claim', 'start' => span_start, 'end' => span_start + marker.length } : nil
          citations << { 'finding_id' => id, 'source_id' => "S#{n}", 'span' => span }
        end
      end
      item[:links].each do |href|
        source = out_sources.find { |s| s['url'] == href } || add_chip(out_sources, href)
        next if ids.include?(source['id'])

        ids << source['id']
        citations << { 'finding_id' => id, 'source_id' => source['id'], 'span' => nil }
      end
      findings << { 'id' => id, 'claim' => item[:text], 'status' => item[:status] == 'contested' ? 'contested' : 'unverified',
                    'source_ids' => ids.uniq, 'quote' => item[:text][QUOTE_RE, 1] }
    end
    { findings: findings, sources: out_sources, citations: citations }
  end

  # An inline link chip names a source that is not in the Sources list; give it
  # the next free id.
  def add_chip(out_sources, href)
    next_n = (out_sources.filter_map { |s| s['id'][1..].to_i }.max || 0) + 1
    source = { 'id' => "S#{next_n}", 'url' => href, 'title' => nil }
    out_sources << source
    source
  end

  def summary_citations(summary, by_number)
    summary.to_enum(:scan, MARKER_RE).flat_map do
      m = Regexp.last_match
      m[1].split(/[,;]/).map { |n| n.strip.to_i }.select { |n| by_number[n] }.map do |n|
        { 'finding_id' => 'summary', 'source_id' => "S#{n}",
          'span' => { 'basis' => 'summary', 'start' => m.begin(0), 'end' => m.end(0) } }
      end
    end
  end

  # none: no http link annotation anywhere; full: every Sources entry carried
  # one; partial: some, but not every, entry did.
  def annotation_level(any_link, unlinked)
    return 'none' unless any_link

    unlinked ? 'partial' : 'full'
  end
end
