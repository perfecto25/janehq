require "db"
require "sqlite3"
require "json"
require "./models/payload"

module JaneHQ
  # A row from the `agents` table (latest known state of one reporting host).
  struct AgentRecord
    getter id : Int64
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
    getter unmonitored : String
    getter alert_count : Int32
    getter check_count : Int32
    getter first_seen : Int64
    getter last_seen : Int64

    def initialize(@id, @hostname, @os, @kernel, @uptime, @cpu_model, @cpu_cores,
                   @cpu_usage, @load_avg, @total_memory, @used_memory, @free_memory,
                   @memory_usage, @jane_version, @unmonitored, @alert_count,
                   @check_count, @first_seen, @last_seen)
    end

    def self.from_rs(rs : DB::ResultSet) : AgentRecord
      new(
        rs.read(Int64), rs.read(String), rs.read(String), rs.read(String),
        rs.read(String), rs.read(String), rs.read(Int32), rs.read(String),
        rs.read(String), rs.read(String), rs.read(String), rs.read(String),
        rs.read(String), rs.read(String), rs.read(String), rs.read(Int32),
        rs.read(Int32), rs.read(Int64), rs.read(Int64),
      )
    end

    def stale?(stale_after : Int32, now : Int64 = Time.utc.to_unix) : Bool
      (now - @last_seen) > stale_after
    end

    def unmonitored_tags : Array(String)
      Array(String).from_json(@unmonitored)
    rescue
      [] of String
    end

    def last_seen_at : Time
      Time.unix(@last_seen)
    end
  end

  # A row from the `checks` table (latest snapshot of one agent's check).
  struct CheckRecord
    getter name : String
    getter status : String
    getter current : String
    getter threshold : String
    getter message : String
    getter tags : String
    getter description : String?

    def initialize(@name, @status, @current, @threshold, @message, @tags, @description)
    end

    def self.from_rs(rs : DB::ResultSet) : CheckRecord
      new(
        rs.read(String), rs.read(String), rs.read(String), rs.read(String),
        rs.read(String), rs.read(String), rs.read(String?),
      )
    end

    def alert? : Bool
      @status == "alert"
    end
  end

  # Persistence layer over SQLite. Holds latest-state per agent (history is a
  # later phase). Safe for concurrent use from the ingest fiber and web fibers
  # via crystal-db's connection pool + a short busy timeout.
  class Storage
    AGENT_COLUMNS = <<-SQL
      id, hostname, os, kernel, uptime, cpu_model, cpu_cores, cpu_usage, load_avg,
      total_memory, used_memory, free_memory, memory_usage, jane_version,
      unmonitored, alert_count, check_count, first_seen, last_seen
      SQL

    UPSERT_AGENT_SQL = <<-SQL
      INSERT INTO agents (
        hostname, os, kernel, uptime, cpu_model, cpu_cores, cpu_usage,
        load_avg, total_memory, used_memory, free_memory, memory_usage,
        jane_version, unmonitored, alert_count, check_count, first_seen, last_seen
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(hostname) DO UPDATE SET
        os=excluded.os, kernel=excluded.kernel, uptime=excluded.uptime,
        cpu_model=excluded.cpu_model, cpu_cores=excluded.cpu_cores,
        cpu_usage=excluded.cpu_usage, load_avg=excluded.load_avg,
        total_memory=excluded.total_memory, used_memory=excluded.used_memory,
        free_memory=excluded.free_memory, memory_usage=excluded.memory_usage,
        jane_version=excluded.jane_version, unmonitored=excluded.unmonitored,
        alert_count=excluded.alert_count, check_count=excluded.check_count,
        last_seen=excluded.last_seen
      SQL

    INSERT_CHECK_SQL = <<-SQL
      INSERT INTO checks
        (agent_id, name, status, current, threshold, message, tags, description)
      VALUES (?,?,?,?,?,?,?,?)
      SQL

    getter db : DB::Database

    def initialize(db_path : String)
      @db = DB.open("sqlite3:#{db_path}?journal_mode=WAL&busy_timeout=5000")
      migrate!
    end

    def close
      @db.close
    end

    private def migrate!
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS agents (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          hostname      TEXT NOT NULL UNIQUE,
          os            TEXT NOT NULL DEFAULT '',
          kernel        TEXT NOT NULL DEFAULT '',
          uptime        TEXT NOT NULL DEFAULT '',
          cpu_model     TEXT NOT NULL DEFAULT '',
          cpu_cores     INTEGER NOT NULL DEFAULT 0,
          cpu_usage     TEXT NOT NULL DEFAULT '',
          load_avg      TEXT NOT NULL DEFAULT '',
          total_memory  TEXT NOT NULL DEFAULT '',
          used_memory   TEXT NOT NULL DEFAULT '',
          free_memory   TEXT NOT NULL DEFAULT '',
          memory_usage  TEXT NOT NULL DEFAULT '',
          jane_version  TEXT NOT NULL DEFAULT '',
          unmonitored   TEXT NOT NULL DEFAULT '[]',
          alert_count   INTEGER NOT NULL DEFAULT 0,
          check_count   INTEGER NOT NULL DEFAULT 0,
          first_seen    INTEGER NOT NULL,
          last_seen     INTEGER NOT NULL
        )
        SQL

      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS checks (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          agent_id    INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
          name        TEXT NOT NULL,
          status      TEXT NOT NULL,
          current     TEXT NOT NULL DEFAULT '',
          threshold   TEXT NOT NULL DEFAULT '',
          message     TEXT NOT NULL DEFAULT '',
          tags        TEXT NOT NULL DEFAULT '[]',
          description  TEXT
        )
        SQL

      @db.exec "CREATE INDEX IF NOT EXISTS idx_checks_agent ON checks(agent_id)"
    end

    # Store one agent report: upsert the agent row (refreshing metrics and the
    # denormalized alert_count) and replace its checks with this snapshot.
    def persist(payload : Payload, now : Int64 = Time.utc.to_unix)
      m = payload.metrics
      alert_count = payload.alert_count
      check_count = payload.checks.size

      @db.transaction do |tx|
        cnn = tx.connection
        cnn.exec(UPSERT_AGENT_SQL,
          m.hostname, m.os, m.kernel, m.uptime, m.cpu_model, m.cpu_cores,
          m.cpu_usage, m.load_avg, m.total_memory, m.used_memory, m.free_memory,
          m.memory_usage, m.jane_version, payload.unmonitored.to_json,
          alert_count, check_count, now, now)

        agent_id = cnn.scalar("SELECT id FROM agents WHERE hostname = ?", m.hostname).as(Int64)

        cnn.exec "DELETE FROM checks WHERE agent_id = ?", agent_id
        payload.checks.each do |c|
          cnn.exec(INSERT_CHECK_SQL,
            agent_id, c.name, c.status, c.current, c.threshold, c.message,
            c.tags.to_json, c.description)
        end
      end
    end

    # All agents, most-alerting first, then most-recently-seen. This ordering
    # is the dashboard's "organize by severity" requirement.
    def all_agents : Array(AgentRecord)
      agents = [] of AgentRecord
      @db.query "SELECT #{AGENT_COLUMNS} FROM agents ORDER BY alert_count DESC, last_seen DESC" do |rs|
        rs.each { agents << AgentRecord.from_rs(rs) }
      end
      agents
    end

    def agent_by_hostname(hostname : String) : AgentRecord?
      @db.query "SELECT #{AGENT_COLUMNS} FROM agents WHERE hostname = ?", hostname do |rs|
        return AgentRecord.from_rs(rs) if rs.move_next
      end
      nil
    end

    def checks_for(agent_id : Int64) : Array(CheckRecord)
      checks = [] of CheckRecord
      @db.query "SELECT name, status, current, threshold, message, tags, description " \
                "FROM checks WHERE agent_id = ? ORDER BY (status='alert') DESC, name", agent_id do |rs|
        rs.each { checks << CheckRecord.from_rs(rs) }
      end
      checks
    end
  end
end
