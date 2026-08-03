require "log"
require "./config"
require "./storage"
require "./ingest/tcp_server"
require "./web/server"

# JaneHQ — admin console + alerting server for the Jane monitoring agent.
#
# Runs two listeners in one process:
#   * the msgpack ingest server (default :25900) for agent reports, and
#   * the Kemal web console (default :80) with an admin login + dashboard.
module JaneHQ
  VERSION = "0.1.0"

  # Cache-busting token appended to /public asset URLs. Kemal's
  # StaticFileHandler only sends ETag/Last-Modified, so browsers happily serve
  # a stale app.css after a rebuild; this changes on every server start.
  ASSET_VERSION = Time.utc.to_unix.to_s

  def self.run
    Log.setup_from_env(default_level: :info)

    config = Config.from_env
    storage = Storage.new(config.db_path)

    ingest = IngestServer.new(storage, port: config.ingest_port)
    spawn ingest.listen

    Web.configure(config, storage)

    Log.for("janehq").info { "console on :#{config.web_port} (admin user: #{config.admin_user})" }
    Kemal.config.port = config.web_port
    Kemal.run
  end
end
