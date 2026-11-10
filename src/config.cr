module JaneHQ
  # Runtime configuration, sourced from environment variables with sane
  # defaults. `JANEHQ_ADMIN_PASSWORD` is the only required setting.
  class Config
    getter admin_user : String
    getter admin_password : String
    getter web_port : Int32
    getter ingest_port : Int32
    getter db_path : String
    getter session_secret : String
    # An agent is considered stale/offline if we haven't heard from it in
    # this many seconds (~3 agent cycles at the default 10s heartbeat).
    getter stale_after : Int32
    # Public URL of the console (e.g. https://janehq.example.com), used to build
    # links in Slack alerts. Nil = no links.
    getter base_url : String?

    def initialize(@admin_user, @admin_password, @web_port, @ingest_port,
                   @db_path, @session_secret, @stale_after, @base_url : String? = nil)
    end

    def self.from_env : Config
      password = ENV["JANEHQ_ADMIN_PASSWORD"]?
      if password.nil? || password.empty?
        abort "JANEHQ_ADMIN_PASSWORD must be set (the console admin password)."
      end

      new(
        admin_user: ENV["JANEHQ_ADMIN_USER"]? || "admin",
        admin_password: password,
        web_port: (ENV["JANEHQ_PORT"]? || "80").to_i,
        ingest_port: (ENV["JANEHQ_INGEST_PORT"]? || "25900").to_i,
        db_path: ENV["JANEHQ_DB_PATH"]? || "./janehq.db",
        session_secret: ENV["JANEHQ_SESSION_SECRET"]? || Random::Secure.hex(32),
        stale_after: (ENV["JANEHQ_STALE_AFTER"]? || "30").to_i,
        base_url: ENV["JANEHQ_BASE_URL"]?.try(&.strip.rstrip('/')).presence,
      )
    end
  end
end
