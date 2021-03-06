require 'wiki/extensions'

module Wiki
  class WikiError < StandardError; end

  class MessageError < WikiError; end

  module Utils
    def self.included(base)
      # Also as class methods
      base.extend self
    end

    def escape_html(html)
      CGI::escapeHTML(html.to_s)
    end

    def forbid(conds)
      failed = conds.keys.select {|key| conds[key]}
      raise(MessageError, failed) if !failed.empty?
    end
  end
end
