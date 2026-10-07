#!/usr/bin/env ruby
# frozen_string_literal: true

# The one markup tokenizer behind the cf:color checker. Both the stray scan
# (ColorScan.markup_file_findings) and the token-file reader
# (ColorCheck.style_block_sheet) consume its events, so a "<style>" that is
# only text (inside a comment, a script string, a quoted attribute value, a
# textarea or a title) is never parsed as CSS by either one.
#
# A single forward pass: it walks literal "<" characters and, in order,
# strips an HTML comment ("<!--...-->") or a CDATA section
# ("<![CDATA[...]]>") as text with no further interpretation; skips closing
# tags, doctypes and processing instructions; and for every other start tag
# reads its attribute list up to the tag's own closing ">" (honoring quoted
# values, unquoted values and Svelte's "{expr}" form), then, for script/style
# (raw text) and textarea/title (RCDATA), consumes the element's content up
# to its matching case-insensitive end tag without lexing any "<" inside it
# as a tag. Every pos is an offset into the raw text as given.
module ColorMarkup
  # One attribute that has a value. name is as written (":fill", "v-bind:x");
  # curly is true for a Svelte-style "{...}" value; bound is true for a
  # ":"/"v-bind:" prefixed name.
  Attr = Struct.new(:tag, :name, :value, :pos, :curly, :bound, keyword_init: true)
  # Content of a script, textarea or title element. attrs maps each
  # downcased attribute name (binding prefix removed) to its last value.
  Raw = Struct.new(:tag, :body, :pos, :attrs, keyword_init: true)
  # Content of a style element, with its media= and lang= values (nil when
  # absent).
  Style = Struct.new(:body, :pos, :media, :lang, keyword_init: true)

  BOUND_ATTR_PREFIX = /\A(?::|v-bind:)/i.freeze
  TAG_NAME = /[a-zA-Z][\w:-]*/.freeze
  ATTR_NAME_TOKEN = /[:@]?[\w.:-]+/.freeze
  # script and style hold raw text (never nested tags); textarea and title
  # hold RCDATA. Content runs to the matching case-insensitive end tag, or
  # end of file when there is none.
  RAW_TEXT_ELEMENTS = %w[script style].freeze
  RCDATA_ELEMENTS = %w[textarea title].freeze

  module_function

  # Yields Attr, Raw and Style events in source order. Returns an
  # Enumerator when called without a block.
  def each_node(text)
    return enum_for(:each_node, text) unless block_given?

    i = 0
    len = text.length
    while i < len
      lt = text.index('<', i)
      break unless lt

      skip_to = skipped_construct_end(text, lt, len)
      if skip_to
        i = skip_to
        next
      end

      name_match = TAG_NAME.match(text, lt + 1)
      unless name_match && name_match.begin(0) == lt + 1
        i = lt + 1
        next
      end

      tag_name = name_match[0].downcase
      attrs = {}
      tag_end = scan_tag_attrs(text, name_match.end(0), len) do |n, v, vs, curly|
        next if v.nil?

        base = n.sub(BOUND_ATTR_PREFIX, '').downcase
        attrs[base] = v
        yield Attr.new(tag: tag_name, name: n, value: v, pos: vs, curly: curly,
                       bound: BOUND_ATTR_PREFIX.match?(n))
      end

      if RAW_TEXT_ELEMENTS.include?(tag_name) || RCDATA_ELEMENTS.include?(tag_name)
        end_match = /<\/#{tag_name}\s*>/i.match(text, tag_end)
        content_end = end_match ? end_match.begin(0) : len
        body = text[tag_end...content_end]
        if tag_name == 'style'
          yield Style.new(body: body, pos: tag_end, media: attrs['media'], lang: attrs['lang'])
        else
          yield Raw.new(tag: tag_name, body: body, pos: tag_end, attrs: attrs)
        end
        i = end_match ? end_match.end(0) : len
      else
        i = tag_end
      end
    end
  end

  # The index just past a comment or CDATA section starting at lt, lt + 1
  # for a closing tag, doctype or processing instruction, or nil when lt
  # opens a start tag candidate.
  def skipped_construct_end(text, lt, len)
    if text[lt, 4] == '<!--'
      close = text.index('-->', lt + 4)
      return close ? close + 3 : len
    end
    if text[lt, 9].casecmp?('<![cdata[')
      close = text.index(']]>', lt + 9)
      return close ? close + 3 : len
    end
    nxt = text[lt + 1]
    return lt + 1 if nxt.nil? || nxt == '/' || nxt == '!' || nxt == '?'

    nil
  end

  # Scans one tag's attribute list starting just after its name, up to the
  # tag's own closing ">" (respecting quotes and Svelte-style "{...}"
  # values), yielding [name, raw_value, value_start_index, curly] for each
  # attribute (raw_value nil when it has none). Returns the index just past
  # the ">".
  def scan_tag_attrs(text, idx, len, &)
    i = idx
    while i < len
      c = text[i]
      if c == '>'
        return i + 1
      elsif c =~ /\s/ || c == '/'
        i += 1
      else
        i = scan_one_tag_attr(text, i, len, &)
      end
    end
    i
  end

  def scan_one_tag_attr(text, i, len, &)
    name_match = ATTR_NAME_TOKEN.match(text, i)
    return i + 1 unless name_match && name_match.begin(0) == i

    name = name_match[0]
    j = name_match.end(0)
    j += 1 while j < len && text[j] =~ /[ \t\r\n]/
    unless j < len && text[j] == '='
      yield(name, nil, nil, false)
      return name_match.end(0)
    end

    j += 1
    j += 1 while j < len && text[j] =~ /[ \t\r\n]/
    scan_tag_attr_value(text, name, j, len, &)
  end

  def scan_tag_attr_value(text, name, j, len)
    if j < len && (text[j] == '"' || text[j] == "'")
      quote = text[j]
      vstart = j + 1
      close = text.index(quote, vstart) || len
      yield(name, text[vstart...close], vstart, false)
      close + 1
    elsif j < len && text[j] == '{'
      depth = 1
      k = j + 1
      while k < len && depth.positive?
        depth += 1 if text[k] == '{'
        depth -= 1 if text[k] == '}'
        k += 1
      end
      vstart = j + 1
      yield(name, text[vstart...(k - 1)], vstart, true)
      k
    else
      vstart = j
      k = j
      k += 1 while k < len && text[k] !~ %r{[\s>/]}
      yield(name, text[vstart...k], vstart, false)
      k
    end
  end
end
