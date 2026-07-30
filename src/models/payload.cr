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
  end
end
