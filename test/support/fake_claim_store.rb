# frozen_string_literal: true

require_relative "../../scripts/change_prod_claim"

# An in-memory stand-in for the console's DynamoDB table: a conditional put
# that refuses an existing key, as `attribute_not_exists(PK)` does. `down`
# simulates a missing table or role.
class FakeClaimStore
  attr_reader :items, :puts

  def initialize(down: false)
    @items = {}
    @puts = 0
    @down = down
  end

  def put(item)
    @puts += 1
    raise ChangeProdClaim::Unavailable, "the claim table could not be written: AccessDenied" if @down

    key = item.fetch("pk").fetch("S")
    raise ChangeProdClaim::Exists, "#{key} is already claimed" if @items.key?(key)

    @items[key] = item
  end
end
