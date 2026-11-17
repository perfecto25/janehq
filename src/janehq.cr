require "log"
require "./config"
require "./bootstrap"
require "./storage"
require "./ago"
require "./ingest/tcp_server"
require "./alerts/notifier"
require "./web/server"

# JaneHQ — admin console + alerting server for the Jane monitoring agent.
#
# Runs two listeners in one process:
#   * the msgpack ingest server (default :25900) for agent reports, and
#   * the Kemal web console (default :80) with an admin login + dashboard.
module JaneHQ
  {% begin %}
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
  {% end %}

  # Cache-busting token appended to /public asset URLs. Kemal's
  # StaticFileHandler only sends ETag/Last-Modified, so browsers happily serve
  # a stale app.css after a rebuild; this changes on every server start.
  ASSET_VERSION = Time.utc.to_unix.to_s

  # The topbar logo, embedded at compile time and inlined into the page by
  # layout.ecr rather than linked as an <img>: inline, its bow and "Jane" paths
  # (fill:currentColor) take the topbar's text colour, while the "HQ" keeps the
  # brand red. The file's XML prolog and Inkscape comment are dropped — they are
  # not valid inside an HTML document.
  LOGO_SVG = {{ read_file("#{__DIR__}/../public/logo.svg") }}.sub(/\A.*?<svg/m, "<svg")

  def self.run
    config = Config.from_env
    # Debug applies to JaneHQ's own sources only: the db driver's debug log would
    # dump every query with its arguments (e.g. password hashes).
    Log.setup do |c|
      backend = ::Log::IOBackend.new
      c.bind "*", ::Log::Severity::Info, backend
      if config.debug?
        {"janehq", "web", "ingest"}.each { |src| c.bind "#{src}.*", ::Log::Severity::Debug, backend }
        c.bind "janehq", ::Log::Severity::Debug, backend
        c.bind "web", ::Log::Severity::Debug, backend
        c.bind "ingest", ::Log::Severity::Debug, backend
      end
    end
    if Config.parse_debug_level(ENV["JANEHQ_DEBUG_LEVEL"]?).nil?
      Log.for("janehq").warn { "JANEHQ_DEBUG_LEVEL must be `info` or `debug`; using info" }
    end
    Log.for("janehq").debug { "debug logging on: web requests and ingested reports are logged in detail" }
    if Config.parse_retention(ENV["JANEHQ_METRICS_RETENTION"]?).nil?
      Log.for("janehq").warn { "JANEHQ_METRICS_RETENTION must be a positive number of days; using #{Config::DEFAULT_METRICS_RETENTION_DAYS}" }
    end
    storage = Storage.new(config.db_path)
    bootstrap_users(config, storage)
    if config.google_partial?
      Log.for("janehq").warn { "Google sign-in is DISABLED: JANEHQ_GOOGLE_CLIENT_ID, JANEHQ_GOOGLE_CLIENT_SECRET and JANEHQ_GOOGLE_DOMAIN must all be set" }
    end

    ingest = IngestServer.new(storage, port: config.ingest_port)
    spawn ingest.listen

    notifier = Notifier.new(storage, config.stale_after, base_url: config.base_url, batch_window: Notifier::BATCH_WINDOW)
    spawn notifier.run

    # Hourly rollups + minute-tier pruning of the metric time series.
    spawn do
      loop do
        begin
          storage.rollup_metrics!(retention_days: config.metrics_retention_days)
        rescue ex
          Log.for("janehq").error(exception: ex) { "metric rollup failed" }
        end
        sleep 5.minutes
      end
    end

    Web.configure(config, storage)

    Log.for("janehq").info { "console on :#{config.web_port} (JANEHQ_UI_PORT)" }
    Kemal.config.port = config.web_port
    Kemal.run
  end
end
