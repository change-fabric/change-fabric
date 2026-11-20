# frozen_string_literal: true

# Regenerates report.pdf, a small synthetic deep research export with the
# required skeleton, footnote markers and link annotations. Hand-assembled PDF
# 1.4 so the fixture needs no PDF library: `ruby build.rb` rewrites report.pdf.
# It is never run by the tests; report.pdf is committed.
RUN_ID = "dr-00000000-0000-4000-8000-000000000001"

LINES = [
  [ "Deep research [" + RUN_ID + "]: Synthetic skeleton report", 14, nil ],
  [ "", 11, nil ],
  [ "Summary", 13, nil ],
  [ "Synthetic sources agree that a small example report parses cleanly. [1]", 11, nil ],
  [ "", 11, nil ],
  [ "Findings", 13, nil ],
  [ '1. Specs written in plain text diff well in review. [1] "plain text diffs cleanly"', 11, nil ],
  [ "2. Generated diagrams stay traceable to their source file. [2, 3]", 11, nil ],
  [ "3. Readers retain more after a short guided walk. [3]", 11, nil ],
  [ "", 11, nil ],
  [ "Sources", 13, nil ],
  [ "1. Example Spec Handbook https://example.org/spec", 11, "https://example.org/spec" ],
  [ "2. Example Diagram Guide https://example.org/diagram", 11, "https://example.org/diagram" ],
  [ "3. Example Study https://example.org/study", 11, "https://example.org/study" ],
  [ "", 11, nil ],
  [ "Unverified", 13, nil ],
  [ "- Adoption figures were not confirmed. [3]", 11, nil ],
  [ "", 11, nil ],
  [ "Contested", 13, nil ],
  [ "- Whether guided walks beat self-paced reading. [2]", 11, nil ]
].freeze

def esc(text) = text.gsub("\\", "\\\\\\\\").gsub("(", '\\(').gsub(")", '\\)')

content = +""
annots = []
y = 760
LINES.each do |text, size, url|
  unless text.empty?
    content << "BT /F1 #{size} Tf 50 #{y} Td (#{esc(text)}) Tj ET\n"
    annots << [ url, 50, y - 3, 50 + (text.length * size * 0.5).round, y + size ] if url
  end
  y -= 22
end

objs = []
objs << "<< /Type /Catalog /Pages 2 0 R >>"
objs << "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
annot_refs = annots.each_index.map { |i| "#{6 + i} 0 R" }.join(" ")
objs << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " \
        "/Resources << /Font << /F1 5 0 R >> >> /Annots [#{annot_refs}] >>"
objs << "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream"
objs << "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
annots.each do |url, x1, y1, x2, y2|
  objs << "<< /Type /Annot /Subtype /Link /Rect [#{x1} #{y1} #{x2} #{y2}] /Border [0 0 0] " \
          "/A << /S /URI /URI (#{url}) >> >>"
end

pdf = +"%PDF-1.4\n"
offsets = []
objs.each_with_index do |body, i|
  offsets << pdf.bytesize
  pdf << "#{i + 1} 0 obj\n#{body}\nendobj\n"
end
xref = pdf.bytesize
pdf << "xref\n0 #{objs.size + 1}\n0000000000 65535 f \n"
offsets.each { |o| pdf << format("%010d 00000 n \n", o) }
pdf << "trailer\n<< /Size #{objs.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
File.binwrite(File.join(__dir__, "report.pdf"), pdf)
