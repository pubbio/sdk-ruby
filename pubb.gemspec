require_relative 'lib/pubb/version'

Gem::Specification.new do |spec|
  spec.name = 'pubb'
  spec.version = Pubb::VERSION
  spec.summary = 'Pubb server SDK for Ruby'
  spec.description = 'Publish Pubb events and authorize private and presence subscriptions from Ruby backends.'
  spec.authors = ['Pubb']
  spec.homepage = 'https://github.com/pubbio/sdk-ruby'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1'
  spec.files = Dir['lib/**/*.rb', 'README.md', 'LICENSE', 'examples/*.rb']
  spec.require_paths = ['lib']
  spec.metadata = {'source_code_uri' => spec.homepage, 'rubygems_mfa_required' => 'true'}
end
