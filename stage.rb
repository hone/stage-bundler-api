#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'netrc'
require 'concurrent'

class BundlerApiFactory
  def initialize(uri = "https://api.heroku.com")
    @netrc = Netrc.read
    @uri   = URI(uri)
  end

  def create(name:, config_vars: {}, stack: "cedar-14", collaborators: [], source: "https://github.com/hone/bundler-api/tarball/master/", database_url: ENV['DATABASE_URL'])
    Net::HTTP.start(@uri.hostname, @uri.port, use_ssl: @uri.scheme == 'https') do |http|
      # create app
      resp = post(
        path: "/app-setups",
        data: <<DATA,
{
  "source_blob": {
    "url": "#{source}"
  },
  "overrides": {
    "env": {
      "DATABASE_URL": "#{database_url}",
      "FOLLOWER_DATABASE_URL": "#{database_url}"
    }
  },
  "app": {
    "name": "#{name}",
    "stack": "#{stack}"
  }
}
DATA
        http: http
      )
      create_json = JSON.parse(resp.body)
      puts "#{name}'s create id: #{create_json["id"]}"

      # wait for app to build
      build_status = "pending"
      while build_status == "pending" do
        resp = get(
          path: "/app-setups/#{create_json["id"]}",
          http: http
        )
        build_json = JSON.parse(resp.body)
        build_status = build_json["status"]
        sleep(5)
      end

      if build_status == "failed"
        puts build_json["manifest_errors"]
        break
      end

      app_name = create_json["app"]["name"]
      puts "Created: #{app_name}"

      patch(
        path: "/apps/#{app_name}/features/log-runtime-metrics",
        data: <<DATA,
{
  "enabled": true
}
DATA
        http: http
      )
      puts "#{app_name}: Setup log-runtime-metrics"

      if config_vars.any?
        patch(
          path: "/apps/#{app_name}/config-vars",
          data: config_vars.to_json,
          http: http
        )
        puts "#{app_name}: Set config vars"
      end

      collaborators.each do |collaborator|
        post(
          path: "/apps/#{app_name}/collaborators",
          data: <<DATA,
{
  "silent": true,
  "user": "#{collaborator}"
}
DATA
          http: http
        )
      end
      puts "#{app_name}: Added collaborators"

      patch(
        path: "/apps/#{app_name}/formation",
        data: <<DATA,
{
  "updates": [
    {
      "process": "web",
      "quantity": 10,
      "size": "2X"
    }
  ]
}
DATA
        http: http
      )
      puts "#{app_name} has been scaled"
    end
  end

  private
  def setup_req(req)
    user, pass = @netrc["api.heroku.com"]
    req.basic_auth(user, pass)
    req.content_type = "application/json"
    req["Accept"] = "application/vnd.heroku+json; version=3"
  end

  def get(path:, http:, quiet: true)
    req = Net::HTTP::Get.new(path)
    setup_req(req)
    resp = http.request(req)
    puts JSON.pretty_generate(JSON.parse(resp.body)) unless quiet

    resp
  end

  %w(post patch).each do |method_name|
    define_method(method_name) do |path:, data:, http:, quiet: true|
      klass = Net::HTTP.const_get(method_name.capitalize)
      req = klass.new(path)
      setup_req(req)
      req.body = data
      resp = http.request(req)
      puts JSON.pretty_generate(JSON.parse(resp.body)) unless quiet

      resp
    end
  end

end

collaborators = %w(troels@heroku.com)
factory       = BundlerApiFactory.new
futures       = []

futures << Concurrent::Future.execute {
  factory.create(
    name: "bundler-api-cedar",
    config_vars: {},
    stack: "cedar",
    collaborators: collaborators
  )
}

futures << Concurrent::Future.execute {
  factory.create(
    name: "bundler-api-cedar-14",
    config_vars: {},
    stack: "cedar-14",
    collaborators: collaborators
  )
}

futures << Concurrent::Future.execute {
  factory.create(
    name: "bundler-api-cedar-14-arena-1",
    config_vars: {MALLOC_ARENA_MAX: "1"},
    stack: "cedar-14",
    collaborators: collaborators
  )
}

futures << Concurrent::Future.execute {
  factory.create(
    name: "bundler-api-cedar-14-arena-2",
    config_vars: {MALLOC_ARENA_MAX: "2"},
    stack: "cedar-14",
    collaborators: collaborators
  )
}

futures.each {|f| f.value }
