require "db"
require "sqlite3"
require "json"
require "./models/payload"
require "./models/alert_rules"

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
          rs.read(Int64)                        # cid
          columns << rs.read(String)             # name
          rs.read(String)                        # type
          rs.read(Int64)                         # notnull
          rs.read(String?)                       # dflt_value
          rs.read(Int64)                         # pk
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
        cnn.exec "DELETE FROM alert_groups WHERE id = ?", id
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
