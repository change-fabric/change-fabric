# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module SecretIntake
  # A 0600 temp file that is zeroed and unlinked on every exit path.
  module SecretFile
    module_function

    def with(content = nil)
      dir = Dir.mktmpdir('secret-intake')
      path = File.join(dir, 'payload')
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(content.to_s) }
      yield path
    ensure
      shred(path) if path
      FileUtils.rm_rf(dir) if dir
    end

    def shred(path)
      return unless File.file?(path)

      File.open(path, 'r+b') { |f| f.write("\0" * f.size) }
      File.unlink(path)
    rescue SystemCallError
      nil
    end
  end
end
