# frozen_string_literal: true

require 'bigdecimal'

# The only code that talks to DynamoDB. The app sees a tiny interface: get, put,
# query, delete and `transact`, an all-or-nothing batch of conditional writes.
# A put carries `absent: true` (the item must not exist) or `expect: {attr =>
# value}` (every attr must equal the value; nil means the attribute is absent).
# `transact` returns false when a condition failed and raises on anything else.
class DynamoStore
  def initialize(table: ENV.fetch('TABLE_NAME'), client: nil)
    @table = table
    @client = client
  end

  def get(pk, sk)
    item = client.get_item(table_name: @table, key: { 'pk' => pk, 'sk' => sk }, consistent_read: true).item
    item && plain(item)
  end

  def query(pk)
    client.query(
      table_name: @table, consistent_read: true, key_condition_expression: '#p = :p',
      expression_attribute_names: { '#p' => 'pk' }, expression_attribute_values: { ':p' => pk }
    ).items.map { |item| plain(item) }
  end

  def transact(ops)
    client.transact_write_items(transact_items: ops.map { |op| transact_item(op) })
    true
  rescue Aws::DynamoDB::Errors::TransactionCanceledException => e
    raise unless e.message.include?('ConditionalCheckFailed') || Array(e.cancellation_reasons).any? { |r| r.code == 'ConditionalCheckFailed' }

    false
  end

  private

  def client
    @client ||= begin
      require 'aws-sdk-dynamodb'
      Aws::DynamoDB::Client.new
    end
  end

  def transact_item(op)
    case op[:op]
    when :put then { put: { table_name: @table, item: op[:item] }.merge(condition(op)) }
    when :delete then { delete: { table_name: @table, key: op[:key] }.merge(condition(op)) }
    when :check then { condition_check: { table_name: @table, key: op[:key] }.merge(condition(op)) }
    else raise ArgumentError, "unknown op #{op[:op].inspect}"
    end
  end

  def condition(op)
    if op[:absent]
      { condition_expression: 'attribute_not_exists(pk)' }
    elsif op[:expect]
      expect_condition(op[:expect])
    elsif op[:exists]
      { condition_expression: 'attribute_exists(pk)' }
    else
      {}
    end
  end

  def expect_condition(expect)
    names = {}
    values = {}
    parts = expect.each_with_index.map do |(attr, value), index|
      names["#e#{index}"] = attr
      next "attribute_not_exists(#e#{index})" if value.nil?

      values[":e#{index}"] = value
      "#e#{index} = :e#{index}"
    end
    out = { condition_expression: parts.join(' AND '), expression_attribute_names: names }
    values.empty? ? out : out.merge(expression_attribute_values: values)
  end

  def plain(value)
    case value
    when Hash then value.to_h { |key, item| [ key, plain(item) ] }
    when Array then value.map { |item| plain(item) }
    when BigDecimal then value.frac.zero? ? value.to_i : value.to_f
    else value
    end
  end
end
