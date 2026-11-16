class NotifierBase
  def deliver(_message)
    raise NotImplementedError
  end
end

class EmailNotifier < NotifierBase
  def deliver(message)
    "email: #{message}"
  end
end

class NotifierFactory
  def self.build
    EmailNotifier.new
  end
end
