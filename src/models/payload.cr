require "json"

module JaneHQ
  # Wire model for what a Jane agent pushes each cycle. Mirrors the agent's
  # structs (jane/src/monitor.cr Check, jane/src/info.cr Metrics). The agent
  # encodes `results.to_json` and then msgpack-encodes that JSON *string*, so
  # on the server we msgpack-decode to a String and then `Payload.from_json`.
  class Payload
    include JSON::Serializable

    getter checks : Array(Check)
    getter metrics : Metrics
    getter unmonitored : Array(String) = [] of String
    # Full agent config (TOML-as-JSON). Captured but unused in phase 1.
    getter config : JSON::Any?

    def alert_count : Int32
      @checks.count(&.alert?)
    end
  end

  class Check
    include JSON::Serializable

    getter name : String
    getter status : String # "ok" or "alert"
    getter current : String
    getter threshold : String
    getter message : String
    getter tags : Array(String) = [] of String
    getter description : String?

    def alert? : Bool
      @status == "alert"
    end
  end

  # One process in the agent's top-N lists. Rates are per second; the agent
  # omits the I/O fields when it can't read them (e.g. Xorg).
  struct ProcDetails
    include JSON::Serializable

    getter cmdline : String? = nil
    getter uptime_seconds : Int64? = nil
    getter user : String? = nil
  end

  struct ProcInfo
    include JSON::Serializable

    getter pid : Int64
    getter name : String
    getter details : ProcDetails? = nil
    getter cpu_pct : Float64 = 0.0
    getter rss_bytes : Int64 = 0_i64
    getter io_read_bps : Float64? = nil
    getter io_write_bps : Float64? = nil

    def io_bps : Float64
      (io_read_bps || 0.0) + (io_write_bps || 0.0)
    end
  end

  struct TopProcs
    include JSON::Serializable

    getter by_memory : Array(ProcInfo) = [] of ProcInfo
    getter by_cpu : Array(ProcInfo) = [] of ProcInfo
    getter by_disk_io : Array(ProcInfo) = [] of ProcInfo
  end

  struct Metrics
    include JSON::Serializable

    getter hostname : String
    getter os : String
    getter kernel : String
    getter uptime : String
    getter cpu_model : String
    getter cpu_cores : Int32
    getter cpu_usage : String
    getter load_avg : String
    getter total_memory : String
    getter used_memory : String
    getter free_memory : String
    getter memory_usage : String
    getter jane_version : String
    # Newer agents only; nil from older ones.
    getter top_procs : TopProcs? = nil
  end
end
