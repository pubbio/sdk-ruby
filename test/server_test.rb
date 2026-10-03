require 'minitest/autorun'
require 'webrick'
require 'pubb'

class ServerTest < Minitest::Test
  def setup
    @status = 202
    @body = JSON.generate(success: true, accepted: true, channels: ['updates'], publicationId: 'pub-1', duplicate: false)
    @requests = []
    started = Queue.new
    @server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [], StartCallback: -> { started << true })
    @server.mount_proc('/') do |req, res|
      @requests << req
      sleep 0.2 if JSON.parse(req.body)['name'] == 'timeout'
      res.status = @status
      res['Retry-After'] = '5'
      res['Location'] = '/redirected'
      res.body = @body
    end
    @thread = Thread.new { @server.start }
    started.pop
    @host = "http://127.0.0.1:#{@server.config[:Port]}"
    @client = Pubb::Server.new(app_id: 'app/id', app_key: 'public-key', app_secret: 'test-secret', api_host: @host)
  end

  def teardown
    @server.shutdown
    @thread.join
  end

  def test_publish_contract
    result = @client.trigger(channel: ['updates', 'room'], name: 'message', data: {'text' => 'Merhaba 🌍'}, socket_id: '1.2', idempotency_key: 'event-1')
    req = @requests.fetch(0)
    assert_equal '/api/apps/app%2Fid/events', req.unparsed_uri
    assert_equal 'Bearer test-secret', req['Authorization']
    assert_equal 'event-1', req['Idempotency-Key']
    assert_equal({'channel' => ['updates', 'room'], 'name' => 'message', 'data' => {'text' => 'Merhaba 🌍'}, 'socket_id' => '1.2'}, JSON.parse(req.body))
    assert_equal 'pub-1', result.publication_id
    refute result.duplicate
  end

  def test_duplicate_and_optional_fields
    @body = @body.sub('false', 'true')
    assert @client.trigger(channel: 'updates', name: 'message', data: nil).duplicate
    assert_nil @requests.first['Idempotency-Key']
    refute JSON.parse(@requests.first.body).key?('socket_id')
  end

  def test_api_error_does_not_echo_body_or_retry
    @status, @body = 429, 'sensitive body'
    error = assert_raises(Pubb::APIError) { @client.trigger(channel: 'updates', name: 'message', data: nil) }
    assert_equal 429, error.status
    assert_equal '5', error.retry_after
    refute_includes error.message, 'sensitive'
    assert_equal 1, @requests.size
  end

  def test_redirect_rejected
    @status = 307
    error = assert_raises(Pubb::APIError) { @client.trigger(channel: 'updates', name: 'message', data: nil) }
    assert_equal 307, error.status
    assert_equal 1, @requests.size
  end

  def test_only_202
    @status = 200
    assert_raises(Pubb::APIError) { @client.trigger(channel: 'updates', name: 'message', data: nil) }
  end

  def test_invalid_response
    good = @body
    ['{}', '[]', 'invalid', good.sub('"duplicate":false', '"extra":true'), good.sub('"accepted":true', '"accepted":false')].each do |body|
      @body = body
      assert_raises(Pubb::ProtocolError) { @client.trigger(channel: 'updates', name: 'message', data: nil) }
    end
  end

  def test_signing_vectors
    assert_equal 'public-key:f3312a32998c7c174fb5d44146dad485d980398fe616181bf1f758764ccf603a', @client.authorize_channel(socket_id: '123.456', channel: 'private-room')['auth']
    assert_equal({'auth' => 'public-key:41d9f92ca8a5496a5f346458be7d75c0d79bce9928260f8d139330140140d939', 'channel_data' => '{"user_id":"user-1","user_info":{"name":"Ada"}}'},
      @client.authorize_presence_channel(socket_id: '123.456', channel: 'presence-room', user_id: 'user-1', user_info: {'name' => 'Ada'}))
    refute_includes @client.inspect, 'test-secret'
  end

  def test_validation_before_network
    [[], [''], ['debug-room'], ['_room'], ['🌍' * 101]].each do |channels|
      assert_raises(ArgumentError) { @client.trigger(channel: channels, name: 'message', data: nil) }
    end
    assert_raises(ArgumentError) { @client.trigger(channel: 'room', name: 'message', data: 'é' * 5120) }
    assert_raises(ArgumentError) { @client.trigger(channel: 'room', name: 'message', data: nil, idempotency_key: "bad\r\nkey") }
    assert_raises(JSON::GeneratorError) { @client.trigger(channel: 'room', name: 'message', data: Float::NAN) }
    assert_raises(ArgumentError) { @client.authorize_channel(socket_id: '1.2', channel: 'presence-room') }
    assert_raises(ArgumentError) { @client.authorize_presence_channel(socket_id: '1.2', channel: 'private-room', user_id: 'user') }
    assert_empty @requests
  end

  def test_configuration
    ['ftp://example.com', 'https://user@example.com', 'https://example.com?q=1'].each do |host|
      assert_raises(ArgumentError) { Pubb::Server.new(app_id: 'id', app_key: 'key', app_secret: 'secret', api_host: host) }
    end
    assert_raises(ArgumentError) { Pubb::Server.new(app_id: 'id', app_key: 'key', app_secret: 'secret', timeout: 0) }
  end

  def test_timeout
    client = Pubb::Server.new(app_id: 'id', app_key: 'key', app_secret: 'secret', api_host: @host, timeout: 0.03)
    assert_raises(Net::ReadTimeout) { client.trigger(channel: 'room', name: 'timeout', data: nil) }
  end
end
