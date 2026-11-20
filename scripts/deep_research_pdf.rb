# frozen_string_literal: true

require 'open3'

# PDF to raw.xml. One interface, one P1 implementation: HostExtractor runs
# `pdftohtml -xml -i -stdout` when it is on the host. The pinned poppler
# container replaces it in P2; until then a missing binary names that phase.
module DeepResearchPdf
  class Error < StandardError; end

  class HostExtractor
    BINARY = 'pdftohtml'

    def available? = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, BINARY)) }

    def extract(pdf_path)
      raise Error, "pdftohtml is not on this host; the pinned poppler container arrives in P2 of the deep-research plan" unless available?

      out, err, status = Open3.capture3(BINARY, '-xml', '-i', '-stdout', pdf_path)
      raise Error, "pdftohtml failed: #{err.strip}" unless status.success?

      out
    end
  end

  module_function

  # Writes the extracted xml to out_xml and returns it.
  def extract(pdf_path, out_xml, extractor: HostExtractor.new)
    xml = extractor.extract(pdf_path)
    File.write(out_xml, xml)
    xml
  end
end
