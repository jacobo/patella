require 'active_support'
require 'json'

module Patella::Patella

  def self.patellas
    @@patellas ||= {}
  end

  def self.included(base)
    base.extend ClassMethods
    base.send :include, Patella::SendLater
  end

  def patella_key(symbol, args)
    id_param = respond_to?(:id) ? self.id : nil
    "patella/#{self.class.to_s}/#{id_param}/#{symbol}/#{Digest::MD5.hexdigest(args.to_json)}"
  end

  module ClassMethods
    def patella_key(symbol, args)
      "patella/#{self.to_s}//#{symbol}/#{Digest::MD5.hexdigest(args.to_json)}"
    end

    class PatellaWrapper
      def initialize(wrapped_method_name, implementation, options)
        @wrapped_method_name = wrapped_method_name
        @implementation = implementation
        @options = options
      end
      def cached_invoke(object, args)
        expires_in = @options[:expires_in]
        soft_expiration = @options[:soft_expiration]
        cache_key = object.patella_key(@wrapped_method_name,args)
        result = args.any? ? object.send(@implementation, *args) : object.send(@implementation)
        json = {'result' => result, 'soft_expiration' => Time.now + expires_in - soft_expiration}.to_json
        Rails.cache.write(cache_key, json, :expires_in => expires_in)
        result
      end
      def invoke(object, args)
        opts = {:no_backgrounding => @options[:no_backgrounding]}
        expires_in = @options[:expires_in]
        soft_expiration = @options[:soft_expiration]
        cached_invoke_method = "caching_#{@wrapped_method_name}".to_sym
        cache_key = object.patella_key(@wrapped_method_name,args)
        promise = { 'promise' => true }

        json = Rails.cache.fetch(cache_key, :expires_in => expires_in, :force => !Rails.caching?) do
          if opts[:no_backgrounding]
            promise['result'] = object.send(cached_invoke_method, args)
            promise.delete('promise')
          else
            promise['result'] = object.send_later(cached_invoke_method, args)   #send_later sends_later when Rails.caching? otherwise sends_now
            promise.delete('promise') unless Rails.caching?
          end
          promise.to_json
        end

        if promise['promise'] && opts[:no_backgrounding]
          promise['result'] = object.send(cached_invoke_method, args)
          promise.delete('promise')
          json = promise.to_json
        end

        loading = nil
        soft_expiration_found = nil
        val = JSON.parse(json)
        if val and !val['promise']
          loading = false
          soft_expiration_found = Time.parse(val['soft_expiration']) rescue nil
          json_val = val
          val = val['result']
        else
          val = promise
          loading = true
        end

        if !loading and soft_expiration_found and Time.now > soft_expiration_found
          expires = soft_expiration + 10*60
          json_val['soft_expiration'] = (Time.now - expires).to_s
          Rails.cache.write(cache_key, json_val, :expires_in => expires)
          object.send_later(cached_invoke_method, args)
        end

        PatellaResult.new val, loading
      end
    end

    def patella_reflex(symbol, options = {})      
      options[:expires_in] ||= 30*60
      options[:soft_expiration] ||= 0
      options[:no_backgrounding] ||= false
      is_class = options[:class_method]

      original_method = :"_unpatellaed_#{symbol}"
      the_patella = PatellaWrapper.new(symbol, original_method, options)
      Patella::Patella.patellas[the_patella.object_id] = the_patella

      method_definitions = <<-EOS, __FILE__, __LINE__ + 1
        if method_defined?(:#{original_method})
          raise "Already patella'd #{symbol}"
        end
        alias #{original_method} #{symbol}

        def caching_#{symbol}(args)
          Patella::Patella.patellas[#{the_patella.object_id}].cached_invoke(self, args)
        end

        def clear_#{symbol}(*args)
          cache_key = self.patella_key('#{symbol}',args)
          Rails.cache.delete(cache_key)
        end

        def #{symbol}(*args)
          Patella::Patella.patellas[#{the_patella.object_id}].invoke(self, args)
        end

        if private_method_defined?(#{original_method.inspect})                   # if private_method_defined?(:_unmemoized_mime_type)
          private #{symbol.inspect}                                              #   private :mime_type
        elsif protected_method_defined?(#{original_method.inspect})              # elsif protected_method_defined?(:_unmemoized_mime_type)
          protected #{symbol.inspect}                                            #   protected :mime_type
        end                                                                      # end
      EOS

      if is_class
        (class << self; self; end).class_eval *method_definitions
      else
        self.class_eval *method_definitions
      end
    end
  end
end

class PatellaResult < ActiveSupport::BasicObject

  def initialize(target=nil, loading=false)
    @target = target
    @loading = loading
  end

  def loading?
    @loading
  end

  def loaded?
    !@loading
  end

  def method_missing(method, *args, &block)
    @target.send(method, *args, &block)
  end
end

