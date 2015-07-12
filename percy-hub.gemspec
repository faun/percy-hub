# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'percy/hub/version'

Gem::Specification.new do |spec|
  spec.name          = 'percy-hub'
  spec.version       = Percy::Hub::VERSION
  spec.authors       = ['Perceptual Inc.']
  spec.email         = ['team@percy.io']
  spec.summary       = %q{Percy Hub}
  spec.description   = %q{}
  spec.homepage      = ''
  spec.license       = ''

  spec.files         = Dir['README.md', 'lib/**/*', 'bin/*']
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_dependency 'redis', '~> 3.2'
  spec.add_dependency 'dogstatsd-ruby', '~> 1.5'
  spec.add_dependency 'syslog-logger', '~> 1.6'

  spec.add_development_dependency 'bundler', '~> 1.7'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'rspec', '~> 3'
  spec.add_development_dependency 'pry'
end