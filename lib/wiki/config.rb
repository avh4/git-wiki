require 'wiki/extensions'
require 'yaml'

module Wiki
  class Config
    def initialize(hash = nil)
      @config = {}
      update(hash) if hash
    end

    def set(key, value)
      key = key.to_sym
      create_accessor(key)
      @config[key] = value.is_a?(Hash) ? Config.new(value) : value
    end

    def update(hash)
      hash.each_pair do |key, value|
        key = key.to_sym
        create_accessor(key)
        if value.is_a?(Hash)
          @config[key] ||= Config.new
          @config[key].update(value)
        else
          @config[key] = value
        end
      end
    end

    def method_missing(mid, *args)
      name = mid.to_s
      if name.ends_with?('=')
        raise(ArgumentError, "wrong number of arguments (#{len} for 1)", caller(1)) if args.length != 1
        raise(TypeError, "can't modify frozen #{self.class}", caller(1)) if frozen?
        name.chop!
        set(name, args[0])
      elsif args.length == 0
        @config[mid] || raise(RuntimeError, "configuration key #{mid} is missing for #{self}")
      else
        raise(NoMethodError, "undefined method #{mid} for #{self}", caller(1))
      end
    end

    def delete(name)
      @config.delete name.to_sym
    end

    def reset
      @config.clear
    end

    def load(file)
      load!(file) if File.file?(file)
    end

    def load!(file)
      update(YAML.load_file(file))
    end

    def self.method_missing(name, *args)
      @instance ||= Config.new
      @instance.__send__(name, *args)
    end

    private

    def create_accessor(key)
      if !respond_to?(key)
        metaclass.class_eval do
          define_method(key) { @config[key] }
          define_method("#{key}=") { |x| @config[key] = x }
        end
      end
    end

  end
end
