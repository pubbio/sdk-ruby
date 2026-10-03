# Pubb Ruby server SDK

Publish events and authorize private/presence subscriptions from Ruby 3.1+.
Uses Ruby's JSON, Net::HTTP and OpenSSL libraries; no external runtime gems.

## Install

The gem is not yet published to RubyGems. Add to your Gemfile:

```ruby
gem 'pubb', git: 'https://github.com/pubbio/sdk-ruby.git', branch: 'main'
```

Run `bundle install`. Commit your application's Gemfile.lock to pin the revision.

## Publish

```ruby
require 'pubb'
pubb = Pubb::Server.new(
  app_id: ENV.fetch('PUBB_APP_ID'), app_key: ENV.fetch('PUBB_APP_KEY'),
  app_secret: ENV.fetch('PUBB_APP_SECRET'), api_host: 'https://api.pubb.io', timeout: 30
)
result = pubb.trigger(channel: ['updates', 'notifications'], name: 'message',
  data: {text: 'Hello'}, socket_id: '123.456', idempotency_key: 'message-42')
puts result.publication_id
```

`socket_id` and `idempotency_key` are optional. HTTP 202 means accepted for
processing, not delivered. Calls block and never retry automatically; keep the
same idempotency key when retrying an event. `Pubb::APIError` exposes `status` and
`retry_after`. `Pubb::ProtocolError` indicates an invalid receipt. Network errors
propagate from Net::HTTP. The timeout applies to connection/read/write operations.
Each call uses its own connection. Redirects are rejected and TLS is verified.
Keep the app secret on your server.

## Authorize subscriptions

After authenticating the session and verifying channel access, return the helper's
hash as JSON from your backend authorization route:

```ruby
pubb.authorize_channel(socket_id: '123.456', channel: 'private-room')
pubb.authorize_presence_channel(socket_id: '123.456', channel: 'presence-room',
  user_id: 'user-1', user_info: {name: 'Ada'})
```

Derive user identity from the session. These helpers sign data, but do not check
permissions. Forward `channel_data` unchanged because its exact bytes are signed.
This uses Pubb's HTTP API and shared HMAC format; it is not a drop-in Pusher HTTP SDK.

## Development

```sh
bundle install
bundle exec rake test
gem build pubb.gemspec
```

Tests use a local HTTP server and fixed cross-language signing vectors. MIT.
