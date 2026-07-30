require "socket"
require "log"
require "./processor"
require "../storage"

module JaneHQ
  # Raw-TCP msgpack listener for Jane agents (default port 25900). Each agent
  # opens a connection, writes one message, and closes it — so one connection
  # equals one report and we read to EOF. No framing/auth (matches the agent).
  class IngestServer
    Log = ::Log.for("ingest")

    def initialize(@storage : Storage, @host : String = "0.0.0.0", @port : Int32 = 25900)
    end

    def listen
      server = TCPServer.new(@host, @port)
      Log.info { "listening for agents on #{@host}:#{@port}" }
      loop do
        client = server.accept
        spawn handle(client)
      end
    end

    private def handle(client : TCPSocket)
      bytes = client.getb_to_end
      return if bytes.empty?

      payload = Processor.process(bytes, @storage)
      Log.info { "report from #{payload.metrics.hostname}: #{payload.checks.size} checks, #{payload.alert_count} alert(s)" }
    rescue ex
      Log.error(exception: ex) { "failed to process agent message" }
    ensure
      client.close rescue nil
    end
  end
end
