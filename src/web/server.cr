require "kemal"
require "kemal-session"
require "html"
require "../config"
require "../storage"

module JaneHQ
  # Web console (Kemal). `configure` wires session config, the auth guard and
  # all routes to the shared Config/Storage. Static assets under ./public are
  # served by Kemal's StaticFileHandler, which runs before the auth guard, so
  # only "/login" needs whitelisting.
  module Web
    @@storage : Storage? = nil
    @@config : Config? = nil

    def self.storage : Storage
      @@storage.not_nil!
    end

    def self.config : Config
      @@config.not_nil!
    end

    def self.authed?(env) : Bool
      !env.session.string?("user").nil?
    end

    def self.configure(config : Config, storage : Storage)
      @@config = config
      @@storage = storage

      Kemal::Session.config do |s|
        s.secret = config.session_secret
        s.cookie_name = "janehq_session"
      end

      before_all do |env|
        unless authed?(env) || env.request.path == "/login"
          env.response.headers["Location"] = "/login"
          halt env, 302
        end
      end

      define_auth_routes
      define_dashboard_routes
    end
  end
end

require "./auth"
require "./dashboard"
