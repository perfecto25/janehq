module JaneHQ
  # One thing an alert group watches: a single host, or a whole host group.
  # Forms post these as `host:web-01` / `group:3` tokens (a host group is
  # referenced by id because its name can be edited, a host by hostname
  # because that is the agent's only wire identifier).
  struct AlertTarget
    KIND_HOST  = "host"
    KIND_GROUP = "group"

    getter kind : String
    getter ref : String
    # What to show in the UI: the hostname, or the host group's current name.
    getter label : String

    def initialize(@kind, @ref, label : String? = nil)
      @label = label || @ref
    end

    def self.host(hostname : String) : AlertTarget
      new(KIND_HOST, hostname)
    end

    def self.group(id : Int64, name : String) : AlertTarget
      new(KIND_GROUP, id.to_s, name)
    end

    # Parses a form token. Returns nil for anything unrecognized so a hand-made
    # POST can't smuggle in a target kind we don't understand.
    def self.parse(token : String) : AlertTarget?
      kind, _, ref = token.partition(':')
      return nil unless kind == KIND_HOST || kind == KIND_GROUP
      return nil if ref.blank?
      new(kind, ref)
    end

    def token : String
      "#{@kind}:#{@ref}"
    end

    def group? : Bool
      @kind == KIND_GROUP
    end

    # Monit-style prefix, so a rule reads "Hostgroup PROD TRADING".
    def display : String
      group? ? "Hostgroup #{@label}" : @label
    end
  end

  # The condition and action vocabularies an alert group is built from. Kept
  # here (not in the DB) because they are properties of the Jane agent's check
  # families, not user data.
  module AlertRules
    # One entry in a picker: the value persisted, plus its display label.
    record Option, value : String, label : String

    # A delivery mechanism. `target_label`/`placeholder` drive the destination
    # field next to the Alert Type picker (public/alerts.js swaps them live).
    record AlertType, value : String, label : String,
      target_label : String, placeholder : String

    # Jane reports each check as "ok" or "alert", which are Succeeded and
    # Failed here; "changed" is a transition between the two, so it is derived
    # when a report lands rather than sent by the agent.
    STATUSES = [
      Option.new("succeeded", "Succeeded"),
      Option.new("failed", "Failed"),
      Option.new("changed", "Changed"),
    ]

    # What a new alert group starts with — the same default M/Monit uses.
    DEFAULT_STATUSES = ["failed", "changed"]

    # The check families the agent emits (jane/src/utils/*.cr). `event_for`
    # maps a reported check name back to one of these.
    EVENTS = [
      Option.new("cpu_usage", "CPU usage"),
      Option.new("cpu_io_wait", "CPU I/O wait"),
      Option.new("load_average", "Load average"),
      Option.new("memory_usage", "Memory usage"),
      Option.new("filesystem_space", "Filesystem space"),
      Option.new("network_interface", "Network interface"),
      Option.new("network_connection", "Network connection"),
      Option.new("bandwidth", "Bandwidth"),
      Option.new("process", "Process"),
      Option.new("file_existence", "File existence"),
      Option.new("file_permission", "File permission"),
      Option.new("file_uid", "File owner"),
      Option.new("file_gid", "File group"),
    ]

    ALERT_TYPES = [
      AlertType.new("exec", "Execute program",
        "Program to run", "/usr/local/bin/page-oncall.sh"),
      AlertType.new("email", "Send email",
        "Email address", "alerts@example.com"),
      AlertType.new("slack", "Slack alert",
        "Slack webhook URL", "https://hooks.slack.com/services/..."),
    ]

    DEFAULT_ALERT_TYPE = "email"

    # How many times an alert fires: once, or repeatedly at ALERT_FREQUENCIES.
    ALERT_COUNTS = [
      Option.new("once", "Once"),
      Option.new("recurring", "Alert by Time Frequency"),
    ]

    DEFAULT_ALERT_COUNT = "once"

    # Repeat interval, in minutes, when alert_count is "recurring".
    ALERT_FREQUENCIES = [
      Option.new("1", "every 1 min"),
      Option.new("3", "every 3 min"),
      Option.new("5", "every 5 min"),
      Option.new("10", "every 10 min"),
      Option.new("15", "every 15 min"),
      Option.new("30", "every 30 min"),
      Option.new("45", "every 45 min"),
      Option.new("60", "every 1 hour"),
      Option.new("120", "every 2 hours"),
      Option.new("180", "every 3 hours"),
      Option.new("360", "every 6 hours"),
      Option.new("720", "every 12 hours"),
      Option.new("1440", "every 24 hours"),
      Option.new("2880", "every 48 hours"),
      Option.new("4320", "every 72 hours"),
      Option.new("10080", "every 168 hours (1 week)"),
    ]

    DEFAULT_ALERT_FREQUENCY_MINUTES = 15

    # Which event family a reported check name belongs to. Order matters: the
    # File attribute checks ("File etc user") are suffixes of the plain
    # existence check ("File etc").
    def self.event_for(check_name : String) : String?
      case check_name
      when "CPU Usage"                          then "cpu_usage"
      when "CPU IO Wait"                        then "cpu_io_wait"
      when "Memory Usage"                       then "memory_usage"
      when .starts_with?("Load Avg")            then "load_average"
      when .starts_with?("Filesystem ")         then "filesystem_space"
      when .starts_with?("Network Interface ")  then "network_interface"
      when .starts_with?("Network Connection ") then "network_connection"
      when .starts_with?("Bandwidth ")          then "bandwidth"
      when .starts_with?("Process ")            then "process"
      when .starts_with?("File ")
        case check_name
        when .ends_with?(" user")  then "file_uid"
        when .ends_with?(" group") then "file_gid"
        when .ends_with?(" mode")  then "file_permission"
        else                            "file_existence"
        end
      end
    end

    # Catalog order, unknown values dropped — how submitted picker values are
    # normalized before they are stored.
    def self.known_statuses(values : Array(String)) : Array(String)
      STATUSES.map(&.value) & values
    end

    def self.known_events(values : Array(String)) : Array(String)
      EVENTS.map(&.value) & values
    end

    def self.status_labels(values : Array(String)) : Array(String)
      STATUSES.select { |o| values.includes?(o.value) }.map(&.label)
    end

    def self.event_labels(values : Array(String)) : Array(String)
      EVENTS.select { |o| values.includes?(o.value) }.map(&.label)
    end

    def self.event_label(value : String) : String
      EVENTS.find { |o| o.value == value }.try(&.label) || value
    end

    # The event a check name belongs to, as a label — shown as a hint beside
    # each service in the form's Service picker.
    def self.event_label_for(check_name : String) : String?
      event_for(check_name).try { |v| event_label(v) }
    end

    def self.alert_type?(value : String) : AlertType?
      ALERT_TYPES.find { |t| t.value == value }
    end

    def self.alert_type(value : String) : AlertType
      alert_type?(value) || ALERT_TYPES.find! { |t| t.value == DEFAULT_ALERT_TYPE }
    end

    def self.alert_count?(value : String) : Option?
      ALERT_COUNTS.find { |o| o.value == value }
    end

    def self.alert_count(value : String) : Option
      alert_count?(value) || ALERT_COUNTS.find! { |o| o.value == DEFAULT_ALERT_COUNT }
    end

    def self.alert_frequency_label(minutes : Int32) : String
      ALERT_FREQUENCIES.find { |o| o.value == minutes.to_s }.try(&.label) || "#{minutes} min"
    end
  end
end
