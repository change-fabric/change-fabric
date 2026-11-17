# frozen_string_literal: true

require 'open3'
require_relative '../../cf_secret_store'
require_relative 'errors'
require_relative '../../path_canon'

module SecretIntake
  module Destinations
    # Sets NAME=value in a local env file. Backs the file up to `<file>.bak`
    # (0600) first, replaces the first NAME= line or appends one, keeps CRLF
    # line endings when the file uses them, and writes atomically: 0600 for a
    # new file, the existing mode otherwise. Inside a git repo where the file
    # is not ignored, appends its repo-relative path to the root .gitignore.
    # Returns status lines; the value is never in them.
    class EnvFile
      SAFE_VALUE = %r{\A[A-Za-z0-9_./:@+=,-]*\z}

      # The file text with NAME set: the first NAME= (or export NAME=) line
      # replaced, else a line appended in the file's own line ending.
      def self.set(text, name, value)
        eol = text.include?("\r\n") ? "\r\n" : "\n"
        line = "#{name}=#{quote(value)}"
        pattern = /^(export[ \t]+)?#{Regexp.escape(name)}[ \t]*=[^\r\n]*/
        return text.sub(pattern) { "#{Regexp.last_match(1)}#{line}" } if text.match?(pattern)

        text.empty? || text.end_with?("\n") ? "#{text}#{line}#{eol}" : "#{text}#{eol}#{line}#{eol}"
      end

      # Bare when safe, else double-quoted with backslash escapes and newlines
      # as \n, the form dotenv loaders read back.
      def self.quote(value)
        text = value.to_s
        return text if text.match?(SAFE_VALUE)

        escaped = text.gsub('\\') { '\\\\' }.gsub('"') { '\\"' }.gsub('$') { '\\$' }
        "\"#{escaped.delete("\r").gsub("\n") { '\\n' }}\""
      end

      # `git` takes an argv array and returns [stdout, stderr, status].
      def initialize(path:, git: Open3.method(:capture3))
        @path, @git = File.expand_path(path), git
      end

      attr_reader :path

      def push(name, value)
        existed = File.file?(@path)
        mode = existed ? File.stat(@path).mode & 0o777 : CfSecretStore::FILE_MODE
        backup if existed
        write(existed ? File.binread(@path) : '', name, value, mode)
        [ "set #{name} in #{@path}#{existed ? " (backup at #{@path}.bak)" : ''}", ignore_line ].compact
      end

      private

      def backup
        CfSecretStore.atomic_write("#{@path}.bak", File.binread(@path))
      rescue SystemCallError => e
        raise WriteFailed, "could not back up #{@path} (#{e.class.name.split('::').last}); nothing written"
      end

      def write(text, name, value, mode)
        CfSecretStore.atomic_write(@path, self.class.set(text, name, value))
        File.chmod(mode, @path)
      rescue SystemCallError => e
        raise WriteFailed, "could not write #{@path} (#{e.class.name.split('::').last}); the original is unchanged"
      end

      def ignore_line
        root = git('rev-parse', '--show-toplevel')&.strip or return nil
        return nil if git('check-ignore', '-q', '--', @path)

        relative = relative_to(root) or return nil
        append_ignore(File.join(root, '.gitignore'), relative)
        "appended /#{relative} to #{File.join(root, '.gitignore')} (it was not ignored)"
      end

      def relative_to(root)
        PathCanon.relative(File.expand_path(@path), root, follow_leaf: false)
      end

      def append_ignore(file, relative)
        existing = File.file?(file) ? File.read(file) : ''
        prefix = existing.empty? || existing.end_with?("\n") ? '' : "\n"
        File.write(file, "#{prefix}/#{relative}\n", mode: 'a')
      end

      # stdout on success, nil on failure or when git is missing.
      def git(*args)
        out, _err, status = @git.call('git', '-C', File.dirname(@path), *args)
        status.success? ? out : nil
      rescue SystemCallError
        nil
      end
    end
  end
end
