# frozen_string_literal: true

require "base64"
require "json"
require "openssl"

# In-memory stand-ins for the console Lambda's DynamoDB store and KMS client.
# The store applies a transaction all or nothing under one mutex, with the same
# condition semantics DynamoStore sends (absent, expect, exists).
class MemoryStore
  attr_reader :items
  attr_accessor :before_commit, :after_commit, :read_delay

  def initialize
    @items = {}
    @lock = Mutex.new
    @read_delay = 0
  end

  def seed(item) = @items[[ item["pk"], item["sk"] ]] = Marshal.load(Marshal.dump(item))

  def get(pk, sk)
    sleep(@read_delay) if @read_delay.positive?
    @lock.synchronize { copy(@items[[ pk, sk ]]) }
  end

  def query(pk) = @lock.synchronize { @items.select { |(p, _), _| p == pk }.values.map { |item| copy(item) } }

  def transact(ops)
    ok = @lock.synchronize do
      raise "injected failure before commit" if take(:before_commit)
      next false unless ops.all? { |op| condition_ok?(op) }

      ops.each { |op| apply(op) }
      true
    end
    raise "injected failure after commit" if ok && take(:after_commit)

    ok
  end

  private

  def take(name)
    return false unless instance_variable_get("@#{name}")

    instance_variable_set("@#{name}", false)
    true
  end

  def copy(item) = item && Marshal.load(Marshal.dump(item))

  def key_of(op) = op[:key] ? [ op[:key]["pk"], op[:key]["sk"] ] : [ op[:item]["pk"], op[:item]["sk"] ]

  def condition_ok?(op)
    current = @items[key_of(op)]
    return current.nil? if op[:absent]
    return !current.nil? if op[:exists]
    return true unless op[:expect]
    return false unless current || op[:expect].values.all?(&:nil?)

    op[:expect].all? { |attr, value| (current || {})[attr] == value }
  end

  def apply(op)
    case op[:op]
    when :put then @items[key_of(op)] = copy(op[:item])
    when :delete then @items.delete(key_of(op))
    end
  end
end

class FakeKms
  attr_reader :signer, :signs

  def initialize(signer)
    @signer = signer
    @signs = 0
  end

  def encrypt(plaintext, context) = JSON.generate("ctx" => context, "seed" => Base64.strict_encode64(plaintext))

  def decrypt(blob, context)
    data = JSON.parse(blob)
    raise "InvalidCiphertext: context mismatch" unless data["ctx"] == context

    Base64.strict_decode64(data["seed"])
  end

  def sign(message)
    @signs += 1
    [ signer.key.sign("SHA256", message), "arn:aws:kms:test:key/receipts" ]
  end
end

class FakeDm
  attr_reader :sent

  def initialize
    @sent = []
  end

  def notify(text) = (@sent << text) && true
end
