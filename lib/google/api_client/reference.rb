# Copyright 2010 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'faraday'
require 'faraday/utils'
require 'multi_json'
require 'compat/multi_json'
require 'addressable/uri'
require 'stringio'
require 'google/api_client/discovery'

# TODO - needs some serious cleanup

module Google
  class APIClient
    class Reference
      MULTIPART_BOUNDARY = "-----------RubyApiMultipartPost".freeze

      def initialize(options={})

        self.connection = options[:connection] || Faraday.default_connection
        self.authorization = options[:authorization]
        self.api_method = options[:api_method]
        
        self.parameters = options[:parameters] || {}
        # These parameters are handled differently because they're not
        # parameters to the API method, but rather to the API system.
        self.parameters['key'] ||= options[:key] if options[:key]
        self.parameters['userIp'] ||= options[:user_ip] if options[:user_ip]

        self.headers = options[:headers] || {}
        if options[:media]
          self.initialize_media_upload
        elsif options[:body]
          self.body = options[:body]
        elsif options[:body_object]
          self.headers['Content-Type'] ||= 'application/json'
          self.body = serialize_body(options[:body_object])
        else
          self.body = ''
        end
        unless self.api_method
          self.http_method = options[:http_method] || 'GET'
          self.uri = options[:uri]
          unless self.parameters.empty?
            self.uri.query = Addressable::URI.form_encode(self.parameters)
          end
        end
      end

      def initialize_media_upload
        self.media = options[:media]
        case self.upload_type
        when "media"
          if options[:body] || options[:body_object] 
            raise ArgumentError, "Can not specify body & body object for simple uploads"
          end
          self.headers['Content-Type'] ||= self.media.content_type
          self.body = self.media
        when "multipart"
          unless options[:body_object] 
            raise ArgumentError, "Multipart requested but no body object"              
          end
          metadata = StringIO.new(serialize_body(options[:body_object]))
          env = {
            :request_headers => {'Content-Type' => "multipart/related;boundary=#{MULTIPART_BOUNDARY}"},
            :request => { :boundary => MULTIPART_BOUNDARY }
          }
          multipart = Faraday::Request::Multipart.new
          self.body = multipart.create_multipart(env, [
            [nil,Faraday::UploadIO.new(metadata, 'application/json', 'file.json')], 
            [nil, self.media]])
          self.headers.update(env[:request_headers])
        when "resumable"
          file_length = self.media.length
          self.headers['X-Upload-Content-Type'] = self.media.content_type
          self.headers['X-Upload-Content-Length'] = file_length.to_s
          if options[:body_object]
            self.headers['Content-Type'] ||= 'application/json'
            self.body = serialize_body(options[:body_object]) 
          else
            self.body = ''
          end
        else
          raise ArgumentError, "Invalid uploadType for media"
        end
      end

      def serialize_body(body)
        return body.to_json if body.respond_to?(:to_json)
        return MultiJson.dump(options[:body_object].to_hash) if body.respond_to?(:to_hash)
        raise TypeError, 'Could not convert body object to JSON.' +
                         'Must respond to :to_json or :to_hash.'
      end

      def media
        return @media
      end

      def media=(media)
        @media = (media)
      end
      
      def upload_type
        return self.parameters['uploadType'] || self.parameters['upload_type']
      end

      def authorization
        return @authorization
      end

      def authorization=(new_authorization)
        @authorization = new_authorization
      end

      def connection
        return @connection
      end

      def connection=(new_connection)
        if new_connection.kind_of?(Faraday::Connection)
          @connection = new_connection
        else
          raise TypeError,
            "Expected Faraday::Connection, got #{new_connection.class}."
        end
      end

      def api_method
        return @api_method
      end

      def api_method=(new_api_method)
        if new_api_method.kind_of?(Google::APIClient::Method) ||
            new_api_method == nil
          @api_method = new_api_method
        else
          raise TypeError,
            "Expected Google::APIClient::Method, got #{new_api_method.class}."
        end
      end

      def parameters
        return @parameters
      end

      def parameters=(new_parameters)
        @parameters = Hash[new_parameters]
      end

      def body
        return @body
      end

      def body=(new_body)
        @body = new_body
      end

      def headers
        return @headers ||= {}
      end

      def headers=(new_headers)
        if new_headers.kind_of?(Array) || new_headers.kind_of?(Hash)
          @headers = new_headers
        else
          raise TypeError, "Expected Hash or Array, got #{new_headers.class}."
        end
      end

      def http_method
        return @http_method ||= self.api_method.http_method
      end

      def http_method=(new_http_method)
        if new_http_method.kind_of?(Symbol)
          @http_method = new_http_method.to_s.downcase.to_sym
        elsif new_http_method.respond_to?(:to_str)
          @http_method = new_http_method.to_s.downcase.to_sym
        else
          raise TypeError,
            "Expected String or Symbol, got #{new_http_method.class}."
        end
      end

      def uri
        return @uri ||= self.api_method.generate_uri(self.parameters)
      end

      def uri=(new_uri)
        @uri = Addressable::URI.parse(new_uri)
      end

      def to_http_request
        request = ( 
          if self.api_method
            self.api_method.generate_request(
              self.parameters, self.body, self.headers, :connection => self.connection
            )
          else
            self.connection.build_request(self.http_method) do |req|
              req.url(self.uri.to_str)
              req.headers.update(self.headers)
              req.body = self.body
            end
          end)
        
        if self.authorization.respond_to?(:generate_authenticated_request)
          request = self.authorization.generate_authenticated_request(
            :request => request,
            :connection => self.connection
          )
        end
        return request
      end

      def to_hash
        options = {}
        if self.api_method
          options[:api_method] = self.api_method
          options[:parameters] = self.parameters
        else
          options[:http_method] = self.http_method
          options[:uri] = self.uri
        end
        options[:headers] = self.headers
        options[:body] = self.body
        options[:connection] = self.connection
        unless self.authorization.nil?
          options[:authorization] = self.authorization
        end
        return options
      end
    end
  end
end
