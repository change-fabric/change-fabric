# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "base64"
require_relative "../scripts/browserless_pdf"

# The report PDF: opened from the mounted run dir, printed only once the page
# says it is ready and its images loaded, refused when one did not.
class BrowserlessPdfTest < Minitest::Test
  FakeSession = Struct.new(:result, :code) do
    def run_function(source)
      self.code = source
      result
    end
  end

  def test_writes_the_pdf_beside_the_page
    Dir.mktmpdir do |dir|
      session = FakeSession.new({ "pdf" => Base64.strict_encode64("%PDF-1.7"), "images" => { "total" => 2, "broken" => 0 } })
      path = BrowserlessPdf.render(dir, session: session)
      assert_equal File.join(dir, "report.pdf"), path
      assert_equal "%PDF-1.7", File.binread(path)
      assert_includes session.code, '"file:///cf-run/report.html"'
      assert_includes session.code, 'hasAttribute("data-cf-ready")'
      assert_includes session.code, "img.complete"
    end
  end

  def test_a_broken_image_is_an_error_not_a_quiet_pdf
    Dir.mktmpdir do |dir|
      session = FakeSession.new({ "pdf" => Base64.strict_encode64("%PDF"), "images" => { "total" => 1, "broken" => 1 } })
      error = assert_raises(BrowserlessPdf::Error) { BrowserlessPdf.render(dir, session: session) }
      assert_includes error.message, "1 image(s)"
      refute File.exist?(File.join(dir, "report.pdf"))
    end
  end

  def test_the_pdf_container_alone_opens_file_urls
    argv = ChangeDocker.browserless_command("cf-change-bl-x", nil, 1, "t", [], { "/run" => "/cf-run" }, allow_file_protocol: true)
    assert_includes argv, "ALLOW_FILE_PROTOCOL=true"
    refute_includes ChangeDocker.browserless_command("cf-change-bl-x", nil, 1, "t"), "ALLOW_FILE_PROTOCOL=true"
  end
end
