require "log"
require "./config"
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
    Log.setup_from_env(default_level: :info)

    config = Config.from_env
    storage = Storage.new(config.db_path)

    ingest = IngestServer.new(storage, port: config.ingest_port)
    spawn ingest.listen

    notifier = Notifier.new(storage, config.stale_after, base_url: config.base_url)
    spawn notifier.run

    Web.configure(config, storage)

    Log.for("janehq").info { "console on :#{config.web_port} (admin user: #{config.admin_user})" }
    Kemal.config.port = config.web_port
    Kemal.run
  end
end
