class User < ApplicationRecord
  def self.lookup(id)
    where(id: id).take
  end
end
