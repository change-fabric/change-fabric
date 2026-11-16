class App
  def call
    NotifierFactory.build.deliver(:ok)
  end
end
