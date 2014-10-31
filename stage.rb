#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'netrc'
require 'concurrent'
require 'okyakusan'

class BundlerApiFactory
  def self.create(name:, config_vars: {}, stack: "cedar-14", collaborators: [], source: "https://github.com/hone/bundler-api/tarball/master/", database_url: ENV['DATABASE_URL'])
    Okyakusan.start do |client|
      # create app
      resp = client.post("/app-setups", data: {
        source_blob: { url: source },
        overrides: {
          env: {
            DATABASE_URL: database_url,
            FOLLOWER_DATABASE_URL: database_url
          }
        },
        app: {
          name: name,
          stack: stack
        }
      })
      create_json = JSON.parse(resp.body)
      puts "#{name}'s create id: #{create_json["id"]}"

      # wait for app to build
      build_status = "pending"
      while build_status == "pending" do
        resp = client.get("/app-setups/#{create_json["id"]}")
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

      client.patch("/apps/#{app_name}/features/log-runtime-metrics", data: {enabled: true })
      puts "#{app_name}: Setup log-runtime-metrics"

      if config_vars.any?
        client.patch("/apps/#{app_name}/config-vars", data: config_vars)
        puts "#{app_name}: Set config vars"
      end

      collaborators.each do |collaborator|
        client.post("/apps/#{app_name}/collaborators", data: {
          silent: true,
          user: collaborator
        })
      end
      puts "#{app_name}: Added collaborators"

      client.patch("/apps/#{app_name}/formation", data: {
        updates: [
          {
            process: "web",
            quantity: 10,
            size: "2X"
          }
        ]
      })
      puts "#{app_name} has been scaled"
    end
  end
end

collaborators = %w(troels@heroku.com)
futures       = []

futures << Concurrent::Future.execute {
  BundlerApiFactory.create(
    name: "bundler-api-cedar",
    config_vars: {},
    stack: "cedar",
    collaborators: collaborators
  )
}

futures << Concurrent::Future.execute {
  BundlerApiFactory.create(
    name: "bundler-api-cedar-14",
    config_vars: {},
    stack: "cedar-14",
    collaborators: collaborators
  )
}

futures << Concurrent::Future.execute {
  BundlerApiFactory.create(
    name: "bundler-api-cedar-14-arena-1",
    config_vars: {MALLOC_ARENA_MAX: "1"},
    stack: "cedar-14",
    collaborators: collaborators
  )
}

futures << Concurrent::Future.execute {
  BundlerApiFactory.create(
    name: "bundler-api-cedar-14-arena-2",
    config_vars: {MALLOC_ARENA_MAX: "2"},
    stack: "cedar-14",
    collaborators: collaborators
  )
}

futures.each {|f| f.value }
