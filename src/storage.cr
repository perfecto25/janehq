require "db"
require "sqlite3"
require "json"
require "./models/payload"
require "./models/alert_rules"
require "./models/user"

module JaneHQ
  # A console user. `password_hash` is bcrypt; `temp_password` is true while the
  # account still has its generated bootstrap password.
  record UserRecord, id : Int64, username : String, password_hash : String,
    role : String, temp_password : Bool, created_at : Int64,
    google_sub : String? = nil, disabled : Bool = false do
    def google? : Bool
      !google_sub.nil?
    end
  end

  # One point of a host's metric series: averages plus CPU/memory peaks (percent).
  record MetricPoint, ts : Int64, cpu_avg : Float64, cpu_max : Float64,
    mem_avg : Float64, mem_max : Float64, load1 : Float64, load5 : Float64, load15 : Float64,
    swap_avg : Float64? = nil, swap_max : Float64? = nil # nil = no swap reported in this bucket

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

  # A row from the `host_groups` table. The seeded "All Hosts" group is the
  # default: its membership is implicit (every agent), so it has no rows in
  # `host_group_members` and cannot be edited or deleted.
  struct GroupRecord
    getter id : Int64
    getter name : String
    getter default : Bool
    getter member_count : Int32

    def initialize(@id, @name, @default, @member_count)
    end

    def self.from_rs(rs : DB::ResultSet) : GroupRecord
      new(rs.read(Int64), rs.read(String), rs.read(Int64) == 1, rs.read(Int32))
    end
  end

  # A row from the `alert_groups` table: one rule — what to watch, which check
  # results to care about, and how to deliver the alert. An empty `services`,
  # `statuses` or `events` list means "any".
  struct AlertGroupRecord
    getter id : Int64
    getter name : String
    getter enabled : Bool
    getter services : Array(String)
    getter statuses : Array(String)
    getter events : Array(String)
    getter alert_type : String
    getter alert_target : String
    getter alert_count : String
    getter alert_frequency_minutes : Int32

    def initialize(@id, @name, @enabled, @services, @statuses, @events,
                   @alert_type, @alert_target, @alert_count, @alert_frequency_minutes)
    end

    def self.from_rs(rs : DB::ResultSet) : AlertGroupRecord
      new(
        rs.read(Int64), rs.read(String), rs.read(Int64) == 1,
        parse_list(rs.read(String)), parse_list(rs.read(String)),
        parse_list(rs.read(String)), rs.read(String), rs.read(String),
        rs.read(String), rs.read(Int32),
      )
    end

    # The three condition lists are stored as JSON arrays, like `checks.tags`.
    def self.parse_list(raw : String) : Array(String)
      Array(String).from_json(raw)
    rescue
      [] of String
    end

    def service_summary : String
      @services.empty? ? "Any Service" : @services.join(", ")
    end

    def status_summary : String
      AlertRules.status_labels(@statuses).join(", ").presence || "Any State"
    end

    def event_summary : String
      AlertRules.event_labels(@events).join(", ").presence || "Any Event"
    end

    def alert_type_label : String
      AlertRules.alert_type?(@alert_type).try(&.label) || @alert_type
    end

    def alert_count_label : String
      AlertRules.alert_count(@alert_count).label
    end

    def alert_frequency_label : String
      AlertRules.alert_frequency_label(@alert_frequency_minutes)
    end
  end

  # Persistence layer over SQLite. Holds latest-state per agent (history is a
  # later phase). Safe for concurrent use from the ingest fiber and web fibers
  # via crystal-db's connection pool + a short busy timeout.
  class Storage
    # Seeded on first migration; shows every agent and is not editable.
    DEFAULT_GROUP_NAME = "All Hosts"

    GROUP_COLUMNS = <<-SQL
      g.id, g.name, g.is_default,
      (SELECT COUNT(*) FROM host_group_members m WHERE m.group_id = g.id)
      SQL

    ALERT_GROUP_COLUMNS = <<-SQL
      id, name, enabled, services, statuses, events, alert_type, alert_target,
      alert_count, alert_frequency_minutes
      SQL

    # The bound values are 'group' (the JOIN's kind test) then the rule id.
    ALERT_GROUP_TARGETS_SQL = <<-SQL
      SELECT t.kind, t.ref, COALESCE(g.name, t.ref)
      FROM alert_group_targets t
      LEFT JOIN host_groups g ON t.kind = ? AND g.id = CAST(t.ref AS INTEGER)
      WHERE t.alert_group_id = ?
      ORDER BY t.kind, COALESCE(g.name, t.ref)
      SQL

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

    INSERT_ALERT_GROUP_SQL = <<-SQL
      INSERT INTO alert_groups
        (name, enabled, services, statuses, events, alert_type, alert_target,
         alert_count, alert_frequency_minutes, created_at)
      VALUES (?,?,?,?,?,?,?,?,?,?)
      SQL

    UPDATE_ALERT_GROUP_SQL = <<-SQL
      UPDATE alert_groups SET
        name = ?, enabled = ?, services = ?, statuses = ?, events = ?,
        alert_type = ?, alert_target = ?, alert_count = ?, alert_frequency_minutes = ?
      WHERE id = ?
      SQL

    METRICS_1M       = "metrics_1m"
    METRICS_1H       = "metrics_1h"
    MINUTE_RETENTION = 7_i64 * 86_400

    UPSERT_METRIC_SQL = <<-SQL
      INSERT INTO metrics_1m (agent_id, ts, n, cpu_sum, cpu_max, mem_sum, mem_max, l1_sum, l5_sum, l15_sum,
                              swap_n, swap_sum, swap_max)
      VALUES (?,?,1,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(agent_id, ts) DO UPDATE SET
        n = n + 1,
        cpu_sum = cpu_sum + excluded.cpu_sum, cpu_max = MAX(cpu_max, excluded.cpu_max),
        mem_sum = mem_sum + excluded.mem_sum, mem_max = MAX(mem_max, excluded.mem_max),
        l1_sum = l1_sum + excluded.l1_sum, l5_sum = l5_sum + excluded.l5_sum,
        l15_sum = l15_sum + excluded.l15_sum,
        swap_n = swap_n + excluded.swap_n, swap_sum = swap_sum + excluded.swap_sum,
        swap_max = MAX(swap_max, excluded.swap_max)
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
      migrate_metrics!
      migrate_procs!
      migrate_procs_history!
      migrate_prefs!
      migrate_users!
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

      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS host_groups (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          name       TEXT NOT NULL UNIQUE,
          is_default INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL
        )
        SQL

      # Membership is keyed by hostname (the agent's only identifier on the
      # wire) so a host can be grouped before it has ever reported.
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS host_group_members (
          group_id INTEGER NOT NULL REFERENCES host_groups(id) ON DELETE CASCADE,
          hostname TEXT NOT NULL,
          PRIMARY KEY (group_id, hostname)
        )
        SQL

      @db.exec "INSERT OR IGNORE INTO host_groups (name, is_default, created_at) VALUES (?, 1, ?)",
        DEFAULT_GROUP_NAME, Time.utc.to_unix

      # One alerting rule. The condition lists (services/statuses/events) are
      # JSON arrays rather than child tables: they are small, always read as a
      # whole, and matched in Crystal against an incoming report.
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS alert_groups (
          id                      INTEGER PRIMARY KEY AUTOINCREMENT,
          name                    TEXT NOT NULL UNIQUE,
          enabled                 INTEGER NOT NULL DEFAULT 1,
          services                TEXT NOT NULL DEFAULT '[]',
          statuses                TEXT NOT NULL DEFAULT '[]',
          events                  TEXT NOT NULL DEFAULT '[]',
          alert_type              TEXT NOT NULL DEFAULT 'email',
          alert_target            TEXT NOT NULL DEFAULT '',
          alert_count             TEXT NOT NULL DEFAULT 'once',
          alert_frequency_minutes INTEGER NOT NULL DEFAULT 5,
          created_at              INTEGER NOT NULL
        )
        SQL

      # alert_count/alert_frequency_minutes were added after the initial
      # release — ALTER TABLE existing databases that predate them.
      columns = [] of String
      @db.query "PRAGMA table_info(alert_groups)" do |rs|
        rs.each do
          rs.read(Int64)             # cid
          columns << rs.read(String) # name
          rs.read(String)            # type
          rs.read(Int64)             # notnull
          rs.read(String?)           # dflt_value
          rs.read(Int64)             # pk
        end
      end
      @db.exec "ALTER TABLE alert_groups ADD COLUMN alert_count TEXT NOT NULL DEFAULT 'once'" unless columns.includes?("alert_count")
      @db.exec "ALTER TABLE alert_groups ADD COLUMN alert_frequency_minutes INTEGER NOT NULL DEFAULT 5" unless columns.includes?("alert_frequency_minutes")

      # What the rule watches: `kind` is 'host' (ref = hostname) or 'group'
      # (ref = host_groups.id as text). Two kinds in one table because the UI
      # picks from a single list of hosts and host groups.
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS alert_group_targets (
          alert_group_id INTEGER NOT NULL REFERENCES alert_groups(id) ON DELETE CASCADE,
          kind           TEXT NOT NULL,
          ref            TEXT NOT NULL,
          PRIMARY KEY (alert_group_id, kind, ref)
        )
        SQL

      # Which alerts a rule has already delivered, so a failing check is not
      # re-sent on every tick (or after a restart). Rows exist only while the
      # alert is active; the notifier prunes them when it recovers.
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS alert_state (
          alert_group_id INTEGER NOT NULL,
          hostname       TEXT NOT NULL,
          check_name     TEXT NOT NULL,
          last_sent_at   INTEGER NOT NULL,
          last_active_at INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (alert_group_id, hostname, check_name)
        )
        SQL
      state_cols = [] of String
      @db.query "PRAGMA table_info(alert_state)" do |rs|
        rs.each do
          rs.read(Int64)
          state_cols << rs.read(String)
          rs.read(String)
          rs.read(Int64)
          rs.read(String?)
          rs.read(Int64)
        end
      end
      @db.exec "ALTER TABLE alert_state ADD COLUMN last_active_at INTEGER NOT NULL DEFAULT 0" unless state_cols.includes?("last_active_at")

      # Acknowledgements: a time-boxed "I know, stop notifying me" on one
      # failing check of one host. Always carries an expiry, so an alert that
      # is still failing when it lapses notifies again.
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS alert_acks (
          hostname       TEXT NOT NULL,
          check_name     TEXT NOT NULL,
          acked_at       INTEGER NOT NULL,
          expires_at     INTEGER NOT NULL,
          last_active_at INTEGER NOT NULL,
          acked_by       TEXT NOT NULL DEFAULT '',
          PRIMARY KEY (hostname, check_name)
        )
        SQL
      ack_cols = [] of String
      @db.query "PRAGMA table_info(alert_acks)" do |rs|
        rs.each do
          rs.read(Int64)
          ack_cols << rs.read(String)
          rs.read(String)
          rs.read(Int64)
          rs.read(String?)
          rs.read(Int64)
        end
      end
      @db.exec "ALTER TABLE alert_acks ADD COLUMN acked_by TEXT NOT NULL DEFAULT ''" unless ack_cols.includes?("acked_by")
    end

    # Time series: values are fixed-point ints (value * 100), tables are
    # WITHOUT ROWID so each row is just the (agent_id, ts) key plus packed ints.
    # Reports are folded into 1-minute buckets as sum/count/max (exact averages
    # survive later rollups); `rollup_metrics!` derives 1-hour buckets and
    # prunes old minutes.
    # Per-user UI preferences (e.g. the dashboard's selected host group), keyed
    # by login name so they survive sessions and re-logins.
    private def migrate_users!
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS users (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          username      TEXT NOT NULL UNIQUE COLLATE NOCASE,
          password_hash TEXT NOT NULL,
          role          TEXT NOT NULL,
          temp_password INTEGER NOT NULL DEFAULT 0,
          created_at    INTEGER NOT NULL
        )
        SQL
      # Google sign-in: a user created via OAuth carries Google's stable account
      # id (`sub`); such users have no usable local password.
      cols = @db.query_all("PRAGMA table_info(users)", as: {Int64, String, String, Int64, String?, Int64}).map(&.[1])
      @db.exec "ALTER TABLE users ADD COLUMN google_sub TEXT" unless cols.includes?("google_sub")
      @db.exec "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_google_sub ON users(google_sub) WHERE google_sub IS NOT NULL"
      @db.exec "ALTER TABLE users ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0" unless cols.includes?("disabled")
    end

    USER_COLUMNS = "id, username, password_hash, role, temp_password, created_at, google_sub, disabled"

    private def read_user(rs) : UserRecord
      UserRecord.new(rs.read(Int64), rs.read(String), rs.read(String), rs.read(String),
        rs.read(Int64) != 0, rs.read(Int64), rs.read(String?), rs.read(Int64) != 0)
    end

    def user_by_google_sub(sub : String) : UserRecord?
      @db.query_one?("SELECT #{USER_COLUMNS} FROM users WHERE google_sub = ?", sub) { |rs| read_user(rs) }
    end

    # Account created on first Google sign-in. The stored hash is not a valid
    # bcrypt string, so password login can never succeed for it.
    def create_google_user(username : String, sub : String, role : String = Role::READ_ONLY,
                           now : Int64 = Time.utc.to_unix) : Int64
      @db.exec("INSERT INTO users (username, password_hash, role, temp_password, created_at, google_sub) VALUES (?,?,?,0,?,?)",
        username, Passwords::NO_PASSWORD, role, now, sub).last_insert_id
    end

    def user_count : Int64
      @db.scalar("SELECT COUNT(*) FROM users").as(Int64)
    end

    def user_by_name(username : String) : UserRecord?
      @db.query_one?("SELECT #{USER_COLUMNS} FROM users WHERE username = ?", username) { |rs| read_user(rs) }
    end

    def user_by_id(id : Int64) : UserRecord?
      @db.query_one?("SELECT #{USER_COLUMNS} FROM users WHERE id = ?", id) { |rs| read_user(rs) }
    end

    def all_users : Array(UserRecord)
      users = [] of UserRecord
      @db.query "SELECT #{USER_COLUMNS} FROM users ORDER BY username COLLATE NOCASE" do |rs|
        rs.each { users << read_user(rs) }
      end
      users
    end

    # Raises on a duplicate username.
    def create_user(username : String, password : String, role : String,
                    temp : Bool = false, now : Int64 = Time.utc.to_unix) : Int64
      @db.exec("INSERT INTO users (username, password_hash, role, temp_password, created_at) VALUES (?,?,?,?,?)",
        username, Passwords.hash(password), role, temp ? 1 : 0, now).last_insert_id
    end

    def set_user_password(id : Int64, password : String, temp : Bool = false)
      @db.exec "UPDATE users SET password_hash = ?, temp_password = ? WHERE id = ?", Passwords.hash(password), temp ? 1 : 0, id
    end

    def set_user_role(id : Int64, role : String)
      @db.exec "UPDATE users SET role = ? WHERE id = ?", role, id
    end

    def set_user_disabled(id : Int64, disabled : Bool)
      @db.exec "UPDATE users SET disabled = ? WHERE id = ?", disabled ? 1 : 0, id
    end

    def delete_user(id : Int64)
      @db.exec "DELETE FROM users WHERE id = ?", id
    end

    def active_superuser_count : Int64
      @db.scalar("SELECT COUNT(*) FROM users WHERE role = ? AND disabled = 0", Role::SUPERUSER).as(Int64)
    end

    def superuser_count : Int64
      @db.scalar("SELECT COUNT(*) FROM users WHERE role = ?", Role::SUPERUSER).as(Int64)
    end

    # Accounts that still have their generated bootstrap password.
    def temp_password_users : Array(String)
      @db.query_all("SELECT username FROM users WHERE temp_password = 1 ORDER BY id", as: String)
    end

    private def migrate_prefs!
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS user_prefs (
          username TEXT NOT NULL,
          key      TEXT NOT NULL,
          value    TEXT NOT NULL,
          PRIMARY KEY (username, key)
        ) WITHOUT ROWID
        SQL
    end

    def pref(username : String, key : String) : String?
      @db.query_one?("SELECT value FROM user_prefs WHERE username = ? AND key = ?", username, key, as: String)
    end

    def set_pref(username : String, key : String, value : String)
      @db.exec "INSERT INTO user_prefs (username, key, value) VALUES (?,?,?) " \
               "ON CONFLICT(username, key) DO UPDATE SET value = excluded.value", username, key, value
    end

    # Latest top-process snapshot per agent (JSON), replaced on every report
    # that carries one.
    private def migrate_procs!
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS agent_procs (
          agent_id   INTEGER PRIMARY KEY REFERENCES agents(id) ON DELETE CASCADE,
          updated_at INTEGER NOT NULL,
          data       TEXT NOT NULL
        )
        SQL
    end

    # Historical top-process snapshots: at most one per PROCS_BUCKET seconds per
    # agent (the first of the bucket). Snapshots older than MINUTE_RETENTION are
    # thinned to one per hour by `rollup_metrics!`; all are dropped past the
    # metrics retention.
    PROCS_HISTORY = "agent_procs_history"
    PROCS_BUCKET  = 300_i64

    private def migrate_procs_history!
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS #{PROCS_HISTORY} (
          agent_id INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
          ts       INTEGER NOT NULL,
          data     TEXT NOT NULL,
          PRIMARY KEY (agent_id, ts)
        ) WITHOUT ROWID
        SQL
    end

    # The newest stored snapshot at or before `at` (unix seconds), with its time.
    def top_procs_at(agent_id : Int64, at : Int64) : {TopProcs, Int64}?
      @db.query_one?("SELECT data, ts FROM #{PROCS_HISTORY} WHERE agent_id = ? AND ts <= ? ORDER BY ts DESC LIMIT 1",
        agent_id, at) do |rs|
        {TopProcs.from_json(rs.read(String)), rs.read(Int64)}
      end
    end

    def top_procs_for(agent_id : Int64) : {TopProcs, Int64}?
      @db.query_one?("SELECT data, updated_at FROM agent_procs WHERE agent_id = ?", agent_id) do |rs|
        {TopProcs.from_json(rs.read(String)), rs.read(Int64)}
      end
    end

    private def migrate_metrics!
      {METRICS_1M, METRICS_1H}.each do |t|
        @db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS #{t} (
            agent_id INTEGER NOT NULL,
            ts       INTEGER NOT NULL,
            n        INTEGER NOT NULL,
            cpu_sum  INTEGER NOT NULL, cpu_max INTEGER NOT NULL,
            mem_sum  INTEGER NOT NULL, mem_max INTEGER NOT NULL,
            l1_sum   INTEGER NOT NULL, l5_sum  INTEGER NOT NULL, l15_sum INTEGER NOT NULL,
            swap_n   INTEGER NOT NULL DEFAULT 0, swap_sum INTEGER NOT NULL DEFAULT 0,
            swap_max INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (agent_id, ts)
          ) WITHOUT ROWID
          SQL
        # Tables created before swap tracking: add the columns (same order as above).
        cols = @db.query_all("PRAGMA table_info(#{t})", as: {Int64, String, String, Int64, String?, Int64}).map(&.[1])
        {"swap_n", "swap_sum", "swap_max"}.each do |c|
          @db.exec "ALTER TABLE #{t} ADD COLUMN #{c} INTEGER NOT NULL DEFAULT 0" unless cols.includes?(c)
        end
      end
    end

    # Swap usage (percent * 100) from the agent's "Swap Usage" check, which is the
    # only place swap is reported. nil when there is no percent-based swap check
    # or the host has no swap ("n/a").
    protected def self.swap_pct(checks : Array(Check)) : Int64?
      checks.each do |c|
        next unless c.name == "Swap Usage" || c.name == "Swap Usage (%)"
        return pct(c.current)
      end
      nil
    end

    protected def self.pct(s : String) : Int64?
      s.strip.chomp('%').to_f?.try { |f| (f * 100).round.to_i64 }
    end

    private def record_metrics(cnn, agent_id : Int64, m : Metrics, now : Int64, swap : Int64? = nil)
      cpu = Storage.pct(m.cpu_usage)
      mem = Storage.pct(m.memory_usage)
      return unless cpu && mem
      load = m.load_avg.split(',').map { |x| x.strip.to_f?.try { |f| (f * 100).round.to_i64 } || 0_i64 }
      (3 - load.size).times { load << 0_i64 }
      cnn.exec(UPSERT_METRIC_SQL, agent_id, now - now % 60, cpu, cpu, mem, mem, load[0], load[1], load[2],
        swap ? 1 : 0, swap || 0_i64, swap || 0_i64)
    end

    # Roll completed hours up from minute buckets, then drop minutes older than
    # MINUTE_RETENTION. Idempotent; call periodically.
    # Rows older than `retention_days` are deleted from both tiers.
    def rollup_metrics!(now : Int64 = Time.utc.to_unix, retention_days : Int32 = 360)
      cutoff = now - retention_days.to_i64 * 86_400
      hour = now - now % 3600
      @db.transaction do |tx|
        cnn = tx.connection
        from = cnn.scalar("SELECT COALESCE(MAX(ts), 0) FROM #{METRICS_1H}").as(Int64)
        cnn.exec <<-SQL, from, hour
          INSERT OR REPLACE INTO #{METRICS_1H}
            (agent_id, ts, n, cpu_sum, cpu_max, mem_sum, mem_max, l1_sum, l5_sum, l15_sum, swap_n, swap_sum, swap_max)
          SELECT agent_id, ts - ts % 3600, SUM(n), SUM(cpu_sum), MAX(cpu_max),
                 SUM(mem_sum), MAX(mem_max), SUM(l1_sum), SUM(l5_sum), SUM(l15_sum),
                 SUM(swap_n), SUM(swap_sum), MAX(swap_max)
          FROM #{METRICS_1M} WHERE ts >= ? AND ts < ?
          GROUP BY agent_id, ts - ts % 3600
          SQL
        cnn.exec "DELETE FROM #{METRICS_1M} WHERE ts < ?", {now - MINUTE_RETENTION, hour, cutoff}.min
        cnn.exec "DELETE FROM #{METRICS_1H} WHERE ts < ?", cutoff
        cnn.exec "DELETE FROM #{PROCS_HISTORY} WHERE ts < ?", cutoff
        fine_cut = now - MINUTE_RETENTION
        cnn.exec "DELETE FROM #{PROCS_HISTORY} WHERE ts < ? AND (agent_id, ts) NOT IN " \
                 "(SELECT agent_id, MIN(ts) FROM #{PROCS_HISTORY} WHERE ts < ? GROUP BY agent_id, ts / 3600)", fine_cut, fine_cut
      end
    end

    # Series for one host between two unix times, averaged (and peak) per
    # bucket. Picks the 1-minute tier when it covers `from`, else hourly, and
    # widens the bucket so at most ~max_points rows come back.
    def metric_series(agent_id : Int64, from : Int64, to : Int64,
                      max_points : Int32 = 600, now : Int64 = Time.utc.to_unix) : Array(MetricPoint)
      fine = from >= now - MINUTE_RETENTION
      table, res = fine ? {METRICS_1M, 60_i64} : {METRICS_1H, 3600_i64}
      step = (((to - from) // max_points.clamp(1, 5000) + res - 1) // res).clamp(1_i64, Int64::MAX) * res
      points = [] of MetricPoint
      @db.query <<-SQL, agent_id, from, to do |rs|
        SELECT ts - ts % #{step}, SUM(n), SUM(cpu_sum), MAX(cpu_max), SUM(mem_sum), MAX(mem_max),
               SUM(l1_sum), SUM(l5_sum), SUM(l15_sum), SUM(swap_n), SUM(swap_sum), MAX(swap_max)
        FROM #{table} WHERE agent_id = ? AND ts >= ? AND ts <= ?
        GROUP BY ts - ts % #{step} ORDER BY 1
        SQL
        rs.each do
          t = rs.read(Int64); n = rs.read(Int64).to_f * 100
          cpu_avg = rs.read(Int64) / n; cpu_max = rs.read(Int64) / 100.0
          mem_avg = rs.read(Int64) / n; mem_max = rs.read(Int64) / 100.0
          l1 = rs.read(Int64) / n; l5 = rs.read(Int64) / n; l15 = rs.read(Int64) / n
          sn = rs.read(Int64); ssum = rs.read(Int64); smax = rs.read(Int64)
          points << MetricPoint.new(t, cpu_avg, cpu_max, mem_avg, mem_max, l1, l5, l15,
            sn > 0 ? ssum / (sn * 100.0) : nil, sn > 0 ? smax / 100.0 : nil)
        end
      end
      points
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
        record_metrics(cnn, agent_id, m, now, Storage.swap_pct(payload.checks))
        if tp = m.top_procs
          cnn.exec("INSERT INTO agent_procs (agent_id, updated_at, data) VALUES (?,?,?) " \
                   "ON CONFLICT(agent_id) DO UPDATE SET updated_at = excluded.updated_at, data = excluded.data",
            agent_id, now, tp.to_json)
          cnn.exec("INSERT OR IGNORE INTO #{PROCS_HISTORY} (agent_id, ts, data) VALUES (?,?,?)",
            agent_id, now - now % PROCS_BUCKET, tp.to_json)
        end

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

    # --- Host groups -------------------------------------------------------

    # Default group first, then alphabetical — the order of the dashboard's
    # group picker.
    def all_groups : Array(GroupRecord)
      groups = [] of GroupRecord
      @db.query "SELECT #{GROUP_COLUMNS} FROM host_groups g ORDER BY g.is_default DESC, g.name" do |rs|
        rs.each { groups << GroupRecord.from_rs(rs) }
      end
      groups
    end

    def group_by_id(id : Int64) : GroupRecord?
      @db.query "SELECT #{GROUP_COLUMNS} FROM host_groups g WHERE g.id = ?", id do |rs|
        return GroupRecord.from_rs(rs) if rs.move_next
      end
      nil
    end

    def default_group : GroupRecord
      @db.query "SELECT #{GROUP_COLUMNS} FROM host_groups g WHERE g.is_default = 1" do |rs|
        return GroupRecord.from_rs(rs) if rs.move_next
      end
      raise "default host group is missing"
    end

    def group_hostnames(group_id : Int64) : Array(String)
      names = [] of String
      @db.query "SELECT hostname FROM host_group_members WHERE group_id = ? ORDER BY hostname", group_id do |rs|
        rs.each { names << rs.read(String) }
      end
      names
    end

    # Raises SQLite3::Exception on a duplicate name (UNIQUE on host_groups.name).
    def create_group(name : String, hostnames : Array(String), now : Int64 = Time.utc.to_unix) : Int64
      id = 0_i64
      @db.transaction do |tx|
        cnn = tx.connection
        cnn.exec "INSERT INTO host_groups (name, is_default, created_at) VALUES (?, 0, ?)", name, now
        id = cnn.scalar("SELECT id FROM host_groups WHERE name = ?", name).as(Int64)
        replace_members(cnn, id, hostnames)
      end
      id
    end

    def update_group(id : Int64, name : String, hostnames : Array(String))
      @db.transaction do |tx|
        cnn = tx.connection
        cnn.exec "UPDATE host_groups SET name = ? WHERE id = ? AND is_default = 0", name, id
        replace_members(cnn, id, hostnames)
      end
    end

    def delete_group(id : Int64)
      @db.transaction do |tx|
        cnn = tx.connection
        # The default group is not deletable, and must keep its members and any
        # alert group targets pointing at it.
        next if cnn.scalar("SELECT COUNT(*) FROM host_groups WHERE id = ? AND is_default = 0", id).as(Int64).zero?

        cnn.exec "DELETE FROM host_group_members WHERE group_id = ?", id
        # Alert groups watching this host group lose that target (foreign keys
        # are not enforced — no PRAGMA foreign_keys — so clean up by hand).
        cnn.exec "DELETE FROM alert_group_targets WHERE kind = ? AND ref = ?",
          AlertTarget::KIND_GROUP, id.to_s
        cnn.exec "DELETE FROM host_groups WHERE id = ?", id
      end
    end

    private def replace_members(cnn, group_id : Int64, hostnames : Array(String))
      cnn.exec "DELETE FROM host_group_members WHERE group_id = ?", group_id
      hostnames.uniq.each do |hostname|
        next if hostname.blank?
        cnn.exec "INSERT OR IGNORE INTO host_group_members (group_id, hostname) VALUES (?, ?)",
          group_id, hostname
      end
    end

    # Agents in one group, in the dashboard's severity order. The default
    # group has no membership rows — it means "everything".
    def agents_in_group(group : GroupRecord) : Array(AgentRecord)
      return all_agents if group.default

      agents = [] of AgentRecord
      @db.query "SELECT #{AGENT_COLUMNS} FROM agents " \
                "WHERE hostname IN (SELECT hostname FROM host_group_members WHERE group_id = ?) " \
                "ORDER BY alert_count DESC, last_seen DESC", group.id do |rs|
        rs.each { agents << AgentRecord.from_rs(rs) }
      end
      agents
    end

    # Only the alerting checks — what the dashboard's Glance popover shows.
    def alert_checks_for(agent_id : Int64) : Array(CheckRecord)
      checks = [] of CheckRecord
      @db.query "SELECT name, status, current, threshold, message, tags, description " \
                "FROM checks WHERE agent_id = ? AND status = 'alert' ORDER BY name", agent_id do |rs|
        rs.each { checks << CheckRecord.from_rs(rs) }
      end
      checks
    end

    # --- Alert groups ------------------------------------------------------

    def all_alert_groups : Array(AlertGroupRecord)
      groups = [] of AlertGroupRecord
      @db.query "SELECT #{ALERT_GROUP_COLUMNS} FROM alert_groups ORDER BY name" do |rs|
        rs.each { groups << AlertGroupRecord.from_rs(rs) }
      end
      groups
    end

    def alert_group_by_id(id : Int64) : AlertGroupRecord?
      @db.query "SELECT #{ALERT_GROUP_COLUMNS} FROM alert_groups WHERE id = ?", id do |rs|
        return AlertGroupRecord.from_rs(rs) if rs.move_next
      end
      nil
    end

    # The hosts and host groups one rule watches, host groups first and each
    # labelled with its current name.
    def alert_group_targets(alert_group_id : Int64) : Array(AlertTarget)
      targets = [] of AlertTarget
      @db.query(ALERT_GROUP_TARGETS_SQL, AlertTarget::KIND_GROUP, alert_group_id) do |rs|
        rs.each do
          targets << AlertTarget.new(rs.read(String), rs.read(String), rs.read(String))
        end
      end
      targets
    end

    # Raises SQLite3::Exception on a duplicate name (UNIQUE on alert_groups.name).
    def create_alert_group(name : String, targets : Array(AlertTarget),
                           services : Array(String), statuses : Array(String),
                           events : Array(String), alert_type : String,
                           alert_target : String,
                           alert_count : String = AlertRules::DEFAULT_ALERT_COUNT,
                           alert_frequency_minutes : Int32 = AlertRules::DEFAULT_ALERT_FREQUENCY_MINUTES,
                           enabled : Bool = true,
                           now : Int64 = Time.utc.to_unix) : Int64
      id = 0_i64
      @db.transaction do |tx|
        cnn = tx.connection
        cnn.exec(INSERT_ALERT_GROUP_SQL,
          name, (enabled ? 1 : 0), services.to_json, statuses.to_json,
          events.to_json, alert_type, alert_target, alert_count,
          alert_frequency_minutes, now)
        id = cnn.scalar("SELECT id FROM alert_groups WHERE name = ?", name).as(Int64)
        replace_targets(cnn, id, targets)
      end
      id
    end

    def update_alert_group(id : Int64, name : String, targets : Array(AlertTarget),
                           services : Array(String), statuses : Array(String),
                           events : Array(String), alert_type : String,
                           alert_target : String, enabled : Bool,
                           alert_count : String = AlertRules::DEFAULT_ALERT_COUNT,
                           alert_frequency_minutes : Int32 = AlertRules::DEFAULT_ALERT_FREQUENCY_MINUTES)
      @db.transaction do |tx|
        cnn = tx.connection
        cnn.exec(UPDATE_ALERT_GROUP_SQL,
          name, (enabled ? 1 : 0), services.to_json, statuses.to_json,
          events.to_json, alert_type, alert_target, alert_count,
          alert_frequency_minutes, id)
        replace_targets(cnn, id, targets)
      end
    end

    def set_alert_group_enabled(id : Int64, enabled : Bool)
      @db.exec "UPDATE alert_groups SET enabled = ? WHERE id = ?", (enabled ? 1 : 0), id
    end

    def delete_alert_group(id : Int64)
      @db.transaction do |tx|
        cnn = tx.connection
        cnn.exec "DELETE FROM alert_group_targets WHERE alert_group_id = ?", id
        cnn.exec "DELETE FROM alert_state WHERE alert_group_id = ?", id
        cnn.exec "DELETE FROM alert_groups WHERE id = ?", id
      end
    end

    # --- Alert delivery state ----------------------------------------------

    # What a rule has delivered for one {hostname, check_name}: when it last
    # sent it, and when the alert was last seen failing (so a flapping check
    # can be told apart from a genuinely recovered one).
    record AlertState, last_sent_at : Int64, last_active_at : Int64

    def alert_states(alert_group_id : Int64) : Hash({String, String}, AlertState)
      states = {} of {String, String} => AlertState
      @db.query "SELECT hostname, check_name, last_sent_at, last_active_at FROM alert_state WHERE alert_group_id = ?",
        alert_group_id do |rs|
        rs.each do
          states[{rs.read(String), rs.read(String)}] = AlertState.new(rs.read(Int64), rs.read(Int64))
        end
      end
      states
    end

    record AlertStateRow, rule_id : Int64, hostname : String, check_name : String,
      last_sent_at : Int64, last_active_at : Int64

    def all_alert_states : Array(AlertStateRow)
      rows = [] of AlertStateRow
      @db.query "SELECT alert_group_id, hostname, check_name, last_sent_at, last_active_at FROM alert_state" do |rs|
        rs.each do
          rows << AlertStateRow.new(rs.read(Int64), rs.read(String), rs.read(String), rs.read(Int64), rs.read(Int64))
        end
      end
      rows
    end

    def touch_alert_active_everywhere(hostname : String, check_name : String, now : Int64)
      @db.exec "UPDATE alert_state SET last_active_at = ? WHERE hostname = ? AND check_name = ?", now, hostname, check_name
    end

    def mark_alert_sent(alert_group_id : Int64, hostname : String, check_name : String, now : Int64)
      @db.exec "INSERT INTO alert_state (alert_group_id, hostname, check_name, last_sent_at, last_active_at) " \
               "VALUES (?,?,?,?,?) " \
               "ON CONFLICT(alert_group_id, hostname, check_name) DO UPDATE SET " \
               "last_sent_at = excluded.last_sent_at, last_active_at = excluded.last_active_at",
        alert_group_id, hostname, check_name, now, now
    end

    def touch_alert_active(alert_group_id : Int64, hostname : String, check_name : String, now : Int64)
      @db.exec "UPDATE alert_state SET last_active_at = ? WHERE alert_group_id = ? AND hostname = ? AND check_name = ?",
        now, alert_group_id, hostname, check_name
    end

    record AckRecord, hostname : String, check_name : String, acked_at : Int64,
      expires_at : Int64, last_active_at : Int64, acked_by : String

    def all_acks : Array(AckRecord)
      acks = [] of AckRecord
      @db.query "SELECT hostname, check_name, acked_at, expires_at, last_active_at, acked_by FROM alert_acks" do |rs|
        rs.each do
          acks << AckRecord.new(rs.read(String), rs.read(String), rs.read(Int64), rs.read(Int64), rs.read(Int64), rs.read(String))
        end
      end
      acks
    end

    # Unexpired acks, by host — what the dashboard shows.
    def active_acks(now : Int64 = Time.utc.to_unix) : Hash(String, Array(AckRecord))
      all_acks.select { |a| a.expires_at > now }.group_by(&.hostname)
    end

    # Ack the given failing checks on a host until `expires_at` (re-acking
    # simply moves the expiry).
    def ack_alerts(hostname : String, check_names : Array(String), expires_at : Int64, now : Int64 = Time.utc.to_unix, by : String = "")
      @db.transaction do |tx|
        check_names.each do |name|
          tx.connection.exec "INSERT INTO alert_acks (hostname, check_name, acked_at, expires_at, last_active_at, acked_by) " \
                             "VALUES (?,?,?,?,?,?) ON CONFLICT(hostname, check_name) DO UPDATE SET " \
                             "acked_at = excluded.acked_at, expires_at = excluded.expires_at, " \
                             "last_active_at = excluded.last_active_at, acked_by = excluded.acked_by",
            hostname, name, now, expires_at, now, by
        end
      end
    end

    def touch_ack_active(hostname : String, check_name : String, now : Int64)
      @db.exec "UPDATE alert_acks SET last_active_at = ? WHERE hostname = ? AND check_name = ?", now, hostname, check_name
    end

    def delete_ack(hostname : String, check_name : String)
      @db.exec "DELETE FROM alert_acks WHERE hostname = ? AND check_name = ?", hostname, check_name
    end

    def delete_host_acks(hostname : String)
      @db.exec "DELETE FROM alert_acks WHERE hostname = ?", hostname
    end

    # Forget what every rule sent for this alert, so it is delivered afresh.
    def clear_alert_state_everywhere(hostname : String, check_name : String)
      @db.exec "DELETE FROM alert_state WHERE hostname = ? AND check_name = ?", hostname, check_name
    end

    def clear_alert_state(alert_group_id : Int64, hostname : String, check_name : String)
      @db.exec "DELETE FROM alert_state WHERE alert_group_id = ? AND hostname = ? AND check_name = ?",
        alert_group_id, hostname, check_name
    end

    # Hostnames a target covers. The default group means every agent; a host
    # target is the hostname itself (it may not have reported yet).
    def target_hostnames(target : AlertTarget) : Array(String)
      if target.group?
        group = group_by_id(target.ref.to_i64? || 0_i64)
        return [] of String if group.nil?
        group.default ? all_agents.map(&.hostname) : group_hostnames(group.id)
      else
        [target.ref]
      end
    end

    private def replace_targets(cnn, alert_group_id : Int64, targets : Array(AlertTarget))
      cnn.exec "DELETE FROM alert_group_targets WHERE alert_group_id = ?", alert_group_id
      targets.each do |target|
        cnn.exec "INSERT OR IGNORE INTO alert_group_targets (alert_group_id, kind, ref) VALUES (?,?,?)",
          alert_group_id, target.kind, target.ref
      end
    end

    # Every distinct check name any agent has reported — the "Service" choices
    # on the alert group form.
    def distinct_check_names : Array(String)
      names = [] of String
      @db.query "SELECT DISTINCT name FROM checks ORDER BY name" do |rs|
        rs.each { names << rs.read(String) }
      end
      names
    end
  end
end
