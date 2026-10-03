require 'pubb'

pubb = Pubb::Server.new(app_id: ENV.fetch('PUBB_APP_ID'), app_key: ENV.fetch('PUBB_APP_KEY'), app_secret: ENV.fetch('PUBB_APP_SECRET'))
puts pubb.trigger(channel: 'updates', name: 'message', data: {text: 'Hello from Ruby'}).publication_id
