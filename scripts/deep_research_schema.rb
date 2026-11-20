# frozen_string_literal: true

# The normalized report schema (version 1) and its validator. This file is the
# authority for the field contract; every backend produces this shape.
module DeepResearchSchema
  VERSION = 1
  BACKENDS = %w[manual api].freeze
  STATUSES = %w[unverified contested verified].freeze
  BASES = %w[claim summary output_text].freeze
  LINK_ANNOTATIONS = %w[none partial full].freeze
  ID = /\Adr-\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  ISO = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/

  module_function

  def validate(report)
    errors = []
    return [ 'report is not an object' ] unless report.is_a?(Hash)

    top(report, errors)
    findings(report, errors)
    sources(report, errors)
    citations(report, errors)
    cost(report['cost'], errors)
    provenance(report['provenance'], errors)
    errors
  end

  def valid?(report) = validate(report).empty?

  def top(report, errors)
    errors << 'schema_version must be 1' unless report['schema_version'] == VERSION
    errors << 'id must be dr-<uuid>' unless report['id'].is_a?(String) && report['id'].match?(ID)
    %w[question model summary prompt_sha256].each { |k| str(report, k, errors) }
    errors << 'backend must be manual or api' unless BACKENDS.include?(report['backend'])
    errors << 'created_at must be ISO 8601 UTC' unless report['created_at'].to_s.match?(ISO)
    errors << 'diagnostics must be an array of strings' unless report['diagnostics'].is_a?(Array) && report['diagnostics'].all?(String)
    errors << 'output_text must be a string or null' unless report.key?('output_text') && nullable_str?(report['output_text'])
  end

  def findings(report, errors)
    list = array(report, 'findings', errors)
    ids = list.map { |f| f.is_a?(Hash) ? f['id'] : nil }
    errors << 'duplicate finding id' if ids.compact.uniq.size != ids.compact.size
    list.each_with_index { |f, i| finding(f, "findings[#{i}]", errors) }
  end

  def finding(finding, at, errors)
    return errors << "#{at} is not an object" unless finding.is_a?(Hash)

    errors << "#{at}.id must be F<n>" unless finding['id'].to_s.match?(/\AF\d+\z/)
    str(finding, 'claim', errors, at)
    errors << "#{at}.status unknown" unless STATUSES.include?(finding['status'])
    errors << "#{at}.source_ids must be an array" unless finding['source_ids'].is_a?(Array)
    errors << "#{at}.quote must be a string or null" unless finding.key?('quote') && nullable_str?(finding['quote'])
    unless finding['unresolved_citations'].is_a?(Integer) && finding['unresolved_citations'] >= 0
      errors << "#{at}.unresolved_citations must be a non-negative integer"
    end
    %w[citation_resolves has_quote].each do |k|
      errors << "#{at}.#{k} must be boolean" unless [ true, false ].include?(finding[k])
    end
  end

  def sources(report, errors)
    list = array(report, 'sources', errors)
    ids = list.map { |s| s.is_a?(Hash) ? s['id'] : nil }
    errors << 'duplicate source id' if ids.compact.uniq.size != ids.compact.size
    list.each_with_index do |source, i|
      next errors << "sources[#{i}] is not an object" unless source.is_a?(Hash)

      errors << "sources[#{i}].id must be S<n>" unless source['id'].to_s.match?(/\AS\d+\z/)
      errors << "sources[#{i}].url must be an absolute http(s) URL" unless source['url'].to_s.match?(%r{\Ahttps?://[^\s/]+})
      errors << "sources[#{i}].title must be a string or null" unless source.key?('title') && nullable_str?(source['title'])
    end
    finding_refs(report, errors)
  end

  def finding_refs(report, errors)
    source_ids = (report['sources'] || []).filter_map { |s| s['id'] if s.is_a?(Hash) }
    (report['findings'] || []).each_with_index do |f, i|
      next unless f.is_a?(Hash) && f['source_ids'].is_a?(Array)

      f['source_ids'].each do |sid|
        errors << "findings[#{i}].source_ids #{sid} does not resolve" unless source_ids.include?(sid)
      end
    end
  end

  def citations(report, errors)
    finding_ids = (report['findings'] || []).filter_map { |f| f['id'] if f.is_a?(Hash) } + [ 'summary' ]
    source_ids = (report['sources'] || []).filter_map { |s| s['id'] if s.is_a?(Hash) }
    array(report, 'citations', errors).each_with_index do |c, i|
      next errors << "citations[#{i}] is not an object" unless c.is_a?(Hash)

      errors << "citations[#{i}].finding_id does not resolve" unless finding_ids.include?(c['finding_id'])
      errors << "citations[#{i}].source_id does not resolve" unless source_ids.include?(c['source_id'])
      span(c, report, "citations[#{i}]", errors)
    end
  end

  def span(citation, report, at, errors)
    return errors << "#{at}.span must be present (null allowed)" unless citation.key?('span')

    span = citation['span']
    return if span.nil?
    return errors << "#{at}.span must be {basis, start, end}" unless span.is_a?(Hash) && BASES.include?(span['basis'])

    text = span_text(citation, span, report)
    s = span['start']
    e = span['end']
    ok = s.is_a?(Integer) && e.is_a?(Integer) && text && s >= 0 && s < e && e <= text.length
    errors << "#{at}.span is outside its text" unless ok
  end

  def span_text(citation, span, report)
    case span['basis']
    when 'summary' then report['summary']
    when 'output_text' then report['output_text']
    else (report['findings'] || []).find { |f| f.is_a?(Hash) && f['id'] == citation['finding_id'] }&.dig('claim')
    end
  end

  def cost(cost, errors)
    return errors << 'cost must be an object' unless cost.is_a?(Hash)
    return if cost['subscription'] == true

    ok = cost['usd'].is_a?(Numeric) && cost['tokens'].is_a?(Hash) && cost['search_calls'].is_a?(Integer)
    errors << 'cost must be {subscription: true} or {usd, tokens, search_calls}' unless ok
  end

  def provenance(prov, errors)
    return errors << 'provenance must be an object' unless prov.is_a?(Hash)

    %w[prompt_sha256 backend model date script_version].each do |k|
      errors << "provenance.#{k} must be a string" unless prov[k].is_a?(String) && !prov[k].empty?
    end
    %w[pdf_sha256 response_id from_run].each do |k|
      errors << "provenance.#{k} must be present (null allowed)" unless prov.key?(k) && nullable_str?(prov[k])
    end
    errors << 'provenance.link_annotations must be none, partial or full' unless LINK_ANNOTATIONS.include?(prov['link_annotations'])
  end

  def array(report, key, errors)
    value = report[key]
    return value if value.is_a?(Array)

    errors << "#{key} must be an array"
    []
  end

  def str(hash, key, errors, at = nil)
    return if hash[key].is_a?(String)

    errors << "#{[ at, key ].compact.join('.')} must be a string"
  end

  def nullable_str?(value) = value.nil? || value.is_a?(String)
end
