module Auditable
  def audit_label
    "audit #{self.class}"
  end
end
