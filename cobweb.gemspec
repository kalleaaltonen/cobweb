# -*- encoding: utf-8 -*-
require "#{File.expand_path("../lib", __FILE__)}/cobweb_version.rb"

Gem::Specification.new do |s|

  s.name              = "cobweb"
  s.version           = CobwebVersion.version
  s.author            = "Stewart McKee"
  s.email             = "stewart@rockwellcottage.com"
  s.homepage          = "http://github.com/stewartmckee/cobweb"
  s.platform          = Gem::Platform::RUBY
  s.description       = "Cobweb is a web crawler that can use resque to cluster crawls to quickly crawl extremely large sites which is much more performant than multi-threaded crawlers.  It is also a standalone crawler that has a sophisticated statistics monitoring interface to monitor the progress of the crawls."
  s.summary           = "Cobweb is a web crawler that can use resque to cluster crawls to quickly crawl extremely large sites faster than multi-threaded crawlers.  It is also a standalone crawler that has a sophisticated statistics monitoring interface to monitor the progress of the crawls."
  s.files             = Dir["lib/cobweb.rb"]
  s.require_path      = "lib"
  s.has_rdoc          = false
  s.license           = 'MIT'
  s.extra_rdoc_files  = ["README.textile"]
  s.add_dependency('redis')
  s.add_dependency('nokogiri')
  s.add_dependency('addressable')
  s.add_dependency('awesome_print')
  s.add_dependency('sinatra')
  s.add_dependency('haml')
  s.add_dependency('redis-namespace')
  s.add_dependency('json')
  s.add_dependency('slop')
end
