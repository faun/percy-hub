lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'percy/hub/version'

Gem::Specification.new do |spec|
  spec.name          = 'percy-hub'
  spec.version       = Percy::Hub::VERSION
  spec.authors       = ['Perceptual Inc.']
  spec.email         = ['team@percy.io']
  spec.summary       = 'Percy::Hub'
  spec.description   = ''
  spec.homepage      = ''
  spec.license       = 'MIT'

  spec.files         = Dir['README.md', 'lib/**/*', 'bin/*']
  spec.executables   = spec.files.grep(/^bin\//) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(/^(test|spec|features)\//)
  spec.require_paths = ['lib']

  # Prevent pushing this gem to RubyGems.org. Only allow pushing to packagecloud
  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = 'https://packagecloud.io'
  else
    raise 'RubyGems 2.0 or newer is required to protect against public gem pushes.'
  end

  spec.add_dependency 'percy-common', '~> 3.1', '>= 3.1.4'
  spec.add_dependency 'redis', '>= 4.1.3'
  spec.add_dependency 'sentry-raven', '>= 2.13.0', '< 3.0'

  spec.add_development_dependency 'bundler', '~> 2.1.4'
  spec.add_development_dependency 'percy-style', '~> 0.7.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3'
  spec.add_development_dependency 'package_cloud'
end
