module JaneHQ
  # Runtime configuration, sourced from environment variables with sane
  # defaults. Nothing is required: with no users, JaneHQ creates a `superjane`
  # superuser with a generated password printed to stdout.
  class Config
    DEFAULT_METRICS_RETENTION_DAYS = 360

    getter admin_user : String
    # Optional: seeds the first superuser when the users table is empty.
    getter admin_password : String?
    # RESET_SUPERUSER=true: on startup, give `superjane` a new generated password
    # (printed to stdout) — recovery for a lost password.
    getter reset_superuser : Bool
    getter web_port : Int32
    # JANEHQ_DEBUG_LEVEL: `info` (default) or `debug`. Debug also logs every web
    # request (secrets redacted) and each ingested report as pretty JSON.
    getter debug_level : String
    getter ingest_port : Int32
    getter db_path : String
    getter session_secret : String
    # An agent is considered stale/offline if we haven't heard from it in
    # this many seconds (~3 agent cycles at the default 10s heartbeat).
    getter stale_after : Int32
    # JANEHQ_METRICS_RETENTION: days of metric history to keep (default 360).
    # Older rows are deleted from the metrics tables.
    getter metrics_retention_days : Int32
    # Public URL of the console (e.g. https://janehq.example.com), used to build
    # links in Slack alerts. Nil = no links.
    getter base_url : String?
    # Google Workspace sign-in. Enabled only when the client id, the client
    # secret AND `google_domain` (the one Workspace domain allowed to sign in,
    # e.g. example.com) are all set; an open "any Google account" mode is not
    # supported.
    getter google_client_id : String?
    getter google_client_secret : String?
    getter google_domain : String?

    def initialize(@admin_user, @admin_password : String?, @web_port, @ingest_port,
                   @db_path, @session_secret, @stale_after, @base_url : String? = nil,
                   @google_client_id : String? = nil, @google_client_secret : String? = nil,
                   @google_domain : String? = nil,
                   @reset_superuser : Bool = false, @debug_level : String = "info",
                   @metrics_retention_days : Int32 = DEFAULT_METRICS_RETENTION_DAYS)
    end

    def google_enabled? : Bool
      !google_client_id.nil? && !google_client_secret.nil? && !google_domain.nil?
    end

    # Some but not all Google settings given — worth a warning at startup.
    def google_partial? : Bool
      !google_enabled? && !(google_client_id.nil? && google_client_secret.nil? && google_domain.nil?)
    end

    def debug? : Bool
      debug_level == "debug"
    end

    # nil when the value is not a known level.
    def self.parse_debug_level(v : String?) : String?
      case (s = v.try(&.strip.downcase).presence)
      when nil, "info" then "info"
      when "debug"     then "debug"
      end
    end

    # nil when the value is not a positive whole number of days.
    def self.parse_retention(v : String?) : Int32?
      s = v.try(&.strip).presence
      return DEFAULT_METRICS_RETENTION_DAYS if s.nil?
      n = s.to_i?
      n if n && n > 0
    end

    private def self.truthy?(v : String?) : Bool
      !v.nil? && {"true", "1", "yes"}.includes?(v.strip.downcase)
    end

    def self.from_env : Config
      password = ENV["JANEHQ_ADMIN_PASSWORD"]?.presence

      new(
        admin_user: ENV["JANEHQ_ADMIN_USER"]? || "admin",
        admin_password: password,
        web_port: (ENV["JANEHQ_UI_PORT"]? || "8086").to_i,
        ingest_port: (ENV["JANEHQ_INGEST_PORT"]? || "25900").to_i,
        db_path: ENV["JANEHQ_DB_PATH"]? || "./janehq.db",
        session_secret: ENV["JANEHQ_SESSION_SECRET"]? || Random::Secure.hex(32),
        stale_after: (ENV["JANEHQ_STALE_AFTER"]? || "30").to_i,
        base_url: ENV["JANEHQ_BASE_URL"]?.try(&.strip.rstrip('/')).presence,
        google_client_id: ENV["JANEHQ_GOOGLE_CLIENT_ID"]?.try(&.strip).presence,
        google_client_secret: ENV["JANEHQ_GOOGLE_CLIENT_SECRET"]?.try(&.strip).presence,
        google_domain: ENV["JANEHQ_GOOGLE_DOMAIN"]?.try(&.strip.downcase).presence,
        debug_level: parse_debug_level(ENV["JANEHQ_DEBUG_LEVEL"]?) || "info",
        metrics_retention_days: parse_retention(ENV["JANEHQ_METRICS_RETENTION"]?) || DEFAULT_METRICS_RETENTION_DAYS,
        reset_superuser: truthy?(ENV["RESET_SUPERUSER"]? || ENV["JANEHQ_RESET_SUPERUSER"]?),
      )
    end
  end
end
