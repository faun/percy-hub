require 'logger'

module Percy
  def self.logger
    @logger ||= Logger.new(STDOUT)
  end
end
