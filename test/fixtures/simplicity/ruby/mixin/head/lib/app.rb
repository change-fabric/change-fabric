class App
  include Auditable

  def call
    audit_label
  end
end
