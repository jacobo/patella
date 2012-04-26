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
      def initialize(symbol, options)
      end
      def cached_invoke(object, the_method, overriden_thing, expires_in, soft_expiration, args)
        cache_key = object.patella_key(the_method,args)
        result = args.any? ? object.send(overriden_thing, *args) : object.send(overriden_thing)
        json = {'result' => result, 'soft_expiration' => Time.now + expires_in - soft_expiration}.to_json
        Rails.cache.write(cache_key, json, :expires_in => expires_in)
        result
      end
    end

    def patella_reflex(symbol, options = {})      
      options[:expires_in] ||= 30*60
      options[:soft_expiration] ||= 0
      options[:no_backgrounding] ||= false
      is_class = options[:class_method]

      original_method = :"_unpatellaed_#{symbol}"
      the_patella = PatellaWrapper.new(symbol, options)
      Patella::Patella.patellas[the_patella.object_id] = the_patella

      method_definitions = <<-EOS, __FILE__, __LINE__ + 1
        if method_defined?(:#{original_method})
          raise "Already patella'd #{symbol}"
        end
        alias #{original_method} #{symbol}

        def caching_#{symbol}(args)
          Patella::Patella.patellas[#{the_patella.object_id}].cached_invoke(self, '#{symbol}', '#{original_method}', #{options[:expires_in]}, #{options[:soft_expiration]}, args)
        end

        def clear_#{symbol}(*args)
          cache_key = self.patella_key('#{symbol}',args)
          Rails.cache.delete(cache_key)
        end

        def #{symbol}(*args)
          opts = {:no_backgrounding => #{options[:no_backgrounding]}}
          cache_key = self.patella_key('#{symbol}',args)
          promise = { 'promise' => true }

          json = Rails.cache.fetch(cache_key, :expires_in => #{options[:expires_in]}, :force => !Rails.caching?) do
            if opts[:no_backgrounding]
              promise['result'] = self.send(:caching_#{symbol}, args)
              promise.delete('promise')
            else
              promise['result'] = self.send_later(:caching_#{symbol}, args)   #send_later sends_later when Rails.caching? otherwise sends_now
              promise.delete('promise') unless Rails.caching?
            end
            promise.to_json
          end

          if promise['promise'] && opts[:no_backgrounding]
            promise['result'] = self.send(:caching_#{symbol}, args)
            promise.delete('promise')
            json = promise.to_json
          end

          val = JSON.parse(json)
          if val and !val['promise']
            loading = false
            soft_expiration = Time.parse(val['soft_expiration']) rescue nil
            json_val = val
            val = val['result']
          else
            val = promise
            loading = true
          end

          if !loading and soft_expiration and Time.now > soft_expiration
            expires = #{options[:soft_expiration]} + 10*60
            json_val['soft_expiration'] = (Time.now - expires).to_s
            Rails.cache.write(cache_key, json_val, :expires_in => expires)
            self.send_later(:caching_#{symbol}, args)
          end

          PatellaResult.new val, loading
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

