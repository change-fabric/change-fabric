# frozen_string_literal: true

require 'openssl'

module ApprovalConsole
  # RFC 6238 time-based one-time passwords (HMAC-SHA1, 6 digits, 30 second
  # step) over RFC 4226 HOTP, with the plus or minus one step window the
  # console accepts. `check` also enforces the fencing rule: a code is
  # accepted only for a step strictly greater than the last accepted one, so a
  # code can be used once and never again.
  module Totp
    STEP_SECONDS = 30
    DIGITS = 6
    WINDOW = 1

    Result = Struct.new(:step, :reason, keyword_init: true) do
      def ok? = reason.nil?
    end

    module_function

    def step_for(time) = time.to_i / STEP_SECONDS

    def code(seed, step, digits: DIGITS)
      mac = OpenSSL::HMAC.digest('SHA1', seed.b, [ step ].pack('Q>'))
      offset = mac.getbyte(-1) & 0x0f
      binary = mac.byteslice(offset, 4).unpack1('N') & 0x7fffffff
      (binary % (10**digits)).to_s.rjust(digits, '0')
    end

    # Returns a Result: step is the matched step on success; reason is
    # :malformed, :invalid or :replay on failure.
    def check(seed, submitted, now:, last_step: nil, digits: DIGITS)
      text = submitted.to_s
      return Result.new(reason: :malformed) unless well_formed?(text, digits)

      matches = matching_steps(seed, text, now, digits)
      return Result.new(reason: :invalid) if matches.empty?

      fresh = matches.select { |step| last_step.nil? || step > last_step }
      fresh.empty? ? Result.new(reason: :replay) : Result.new(step: fresh.max)
    end

    def well_formed?(text, digits) = text.match?(/\A\d{#{digits}}\z/)

    # Steps inside the plus or minus WINDOW whose code equals the submitted one.
    def matching_steps(seed, text, now, digits)
      current = step_for(now)
      ((current - WINDOW)..(current + WINDOW)).select do |step|
        same_code?(code(seed, step, digits: digits), text)
      end
    end

    def same_code?(left, right) = OpenSSL.fixed_length_secure_compare(left, right)
  end

  # RFC 4648 base32, the encoding an authenticator app takes a seed in.
  module Base32
    ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    BITS_PER_CHAR = 5

    module_function

    def encode(bytes)
      bits = bytes.b.unpack1('B*')
      bits = bits.ljust(padded_length(bits.length), '0')
      bits.scan(/.{5}/).map { |chunk| ALPHABET[chunk.to_i(2)] }.join
    end

    def decode(text)
      clean = text.to_s.upcase.delete(' =\-')
      raise ArgumentError, 'not base32' unless clean.match?(/\A[A-Z2-7]+\z/)

      bits = clean.each_char.map { |char| ALPHABET.index(char).to_s(2).rjust(BITS_PER_CHAR, '0') }.join
      [ bits[0, bits.length - (bits.length % 8)] ].pack('B*')
    end

    # Rounds a bit count up to a whole number of base32 characters.
    def padded_length(count) = (count / BITS_PER_CHAR.to_f).ceil * BITS_PER_CHAR
  end
end
