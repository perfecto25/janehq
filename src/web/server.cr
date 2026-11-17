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

    SENSITIVE_PARAM = /pass|secret|token|code|state|confirm|current/i

    def self.debug_params(env) : String
      pairs = [] of String
      {env.params.query, env.params.body}.each do |params|
        params.each do |k, v|
          pairs << "#{k}=#{SENSITIVE_PARAM.matches?(k) ? "[redacted]" : v.inspect}"
        end
      end
      pairs.empty? ? "" : "params: #{pairs.join(" ")}"
    end

    def self.configure(config : Config, storage : Storage)
      @@config = config
      @@storage = storage

      Kemal::Session.config do |s|
        s.secret = config.session_secret
        s.cookie_name = "janehq_session"
      end

      # Debug level: log every call (method, path, params) and its status.
      # Secrets in params are redacted.
      before_all do |env|
        if config.debug?
          Log.for("web").debug { "--> #{env.request.method} #{env.request.resource} #{debug_params(env)}" }
        end
      end
      after_all do |env|
        if config.debug?
          Log.for("web").debug { "<-- #{env.response.status_code} #{env.request.method} #{env.request.path}" }
        end
      end

      before_all do |env|
        if denied = guard(env)
          halt env, denied[0], denied[1]
        end
      end

      define_auth_routes
      define_dashboard_routes
      define_group_routes
      define_alert_group_routes
      define_metrics_routes
      define_user_routes
      define_admin_routes
    end
  end
end

require "./google"
require "./auth"
require "./dashboard"
require "./groups"
require "./alert_groups"
require "./metrics"
require "./users"
require "./admin"
