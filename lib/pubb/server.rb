require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module Pubb
  class APIError < StandardError
    attr_reader :status, :retry_after
    def initialize(status, retry_after = nil)
      @status, @retry_after = status, retry_after
      super("Pubb API returned HTTP #{status}")
    end
  end
  class ProtocolError < StandardError; end

  # HTTP 202 is acceptance for processing, not a delivery receipt.
  TriggerResponse = Struct.new(:success, :accepted, :channels, :publication_id, :duplicate, keyword_init: true)

  class Server
    def initialize(app_id:, app_key:, app_secret:, api_host: 'https://api.pubb.io', timeout: 30)
      [app_id, app_key, app_secret].each { |value| require_text(value, 'credential') }
      raise ArgumentError, 'Credentials cannot contain newlines' if [app_id, app_key, app_secret].any? { |s| s.match?(/[\r\n]/) }
      host = URI.parse(api_host)
      unless %w[http https].include?(host.scheme) && host.host && !host.userinfo && !host.query && !host.fragment
        raise ArgumentError, 'api_host must be an HTTP(S) URL without credentials, query or fragment'
      end
      @timeout = Float(timeout)
      raise ArgumentError, 'timeout must be positive and finite' unless @timeout.finite? && @timeout.positive?
      @key, @secret = app_key.dup.freeze, app_secret.dup.freeze
      @endpoint = URI.parse("#{api_host.sub(%r{/+\z}, '')}/api/apps/#{URI.encode_www_form_component(app_id).gsub('+', '%20')}/events")
    end

    def inspect
      '#<Pubb::Server>'
    end

    # Synchronous; uses a fresh HTTP connection per call and never retries automatically.
    def trigger(channel:, name:, data:, socket_id: nil, idempotency_key: nil)
      channels = channel.is_a?(String) ? [channel] : channel
      raise ArgumentError, 'Use 1 to 100 channels' unless channels.is_a?(Array) && (1..100).cover?(channels.length)
      channels.each do |item|
        require_text(item, 'channel', 200)
        raise ArgumentError, 'Reserved channel name' if item.start_with?('debug-', '_')
      end
      require_text(name, 'name', 200)
      encoded = JSON.generate(data)
      raise ArgumentError, 'data exceeds 10 KiB of JSON' if encoded.bytesize > 10_240
      body = "{\"channel\":#{JSON.generate(channel)},\"name\":#{JSON.generate(name)},\"data\":#{encoded}"
      unless socket_id.nil?
        require_text(socket_id, 'socket_id', 100)
        body += ",\"socket_id\":#{JSON.generate(socket_id)}"
      end
      body += '}'
      request = Net::HTTP::Post.new(@endpoint.request_uri)
      request['Authorization'] = "Bearer #{@secret}"
      request['Content-Type'] = 'application/json'
      unless idempotency_key.nil?
        unless idempotency_key.is_a?(String) && idempotency_key.match?(/\A[\x21-\x7e]{1,128}\z/)
          raise ArgumentError, 'Invalid idempotency key'
        end
        request['Idempotency-Key'] = idempotency_key
      end
      request.body = body
      http = Net::HTTP.new(@endpoint.host, @endpoint.port)
      http.use_ssl = @endpoint.scheme == 'https'
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout
      http.max_retries = 0
      raw = +''
      http.start do |session|
        session.request(request) do |response|
          raise APIError.new(response.code.to_i, response['Retry-After']) unless response.code.to_i == 202
          response.read_body do |chunk|
            raw << chunk
            raise ProtocolError, 'Pubb response is too large' if raw.bytesize > 128 * 1024
          end
        end
      end
      parse_receipt(raw)
    end

    # Check the authenticated user's channel permission in your backend before signing.
    def authorize_channel(socket_id:, channel:)
      validate_auth(socket_id, channel, 'private-')
      {'auth' => sign("#{socket_id}:#{channel}")}
    end

    def authorize_presence_channel(socket_id:, channel:, user_id:, user_info: nil)
      validate_auth(socket_id, channel, 'presence-')
      require_text(user_id, 'user_id')
      user = {'user_id' => user_id}
      user['user_info'] = user_info unless user_info.nil?
      data = JSON.generate(user)
      {'auth' => sign("#{socket_id}:#{channel}:#{data}"), 'channel_data' => data}
    end

    private

    def parse_receipt(raw)
      result = JSON.parse(raw)
      unless result.is_a?(Hash) && result['success'] == true && result['accepted'] == true &&
          result['channels'].is_a?(Array) && !result['channels'].empty? &&
          result['channels'].all? { |c| c.is_a?(String) && !c.empty? } &&
          result['publicationId'].is_a?(String) && !result['publicationId'].empty? &&
          [true, false].include?(result['duplicate'])
        raise ProtocolError, 'Pubb API returned an invalid acceptance response'
      end
      TriggerResponse.new(success: true, accepted: true, channels: result['channels'].freeze,
        publication_id: result['publicationId'], duplicate: result['duplicate']).freeze
    rescue JSON::ParserError
      raise ProtocolError, 'Pubb API returned invalid JSON', cause: nil
    end

    def sign(value)
      "#{@key}:#{OpenSSL::HMAC.hexdigest('SHA256', @secret, value)}"
    end

    def require_text(value, name, limit = nil)
      unless value.is_a?(String) && !value.strip.empty? && (!limit || value.encode(Encoding::UTF_16LE).bytesize / 2 <= limit)
        raise ArgumentError, "Invalid #{name}"
      end
    end

    def validate_auth(socket_id, channel, prefix)
      require_text(socket_id, 'socket_id', 100)
      require_text(channel, 'channel', 200)
      raise ArgumentError, "Expected a #{prefix} channel" unless channel.start_with?(prefix)
    end
  end
end
