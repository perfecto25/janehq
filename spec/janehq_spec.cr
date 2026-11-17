require "./spec_helper"

# A report JSON in exactly the shape the Jane agent produces
# (jane/src/daemon.cr builds this hash and calls `results.to_json`).
def sample_report_json(hostname : String, fs_status : String = "ok") : String
  <<-JSON
  {
    "checks": [
      {"name":"CPU Usage","status":"ok","current":"2.35%","threshold":"7.00%","message":"Within limits","tags":[],"description":null},
      {"name":"Memory Usage","status":"ok","current":"45.30%","threshold":"85.00%","message":"Within limits","tags":["memory"],"description":null},
      {"name":"Filesystem root","status":"#{fs_status}","current":"92.50%","threshold":"85.00%","message":"Filesystem usage","tags":[],"description":null}
    ],
    "metrics": {
      "hostname":"#{hostname}","os":"Fedora Linux 43","kernel":"6.19.8","uptime":"5d",
      "cpu_model":"Intel i9","cpu_cores":16,"cpu_usage":"8.45%","load_avg":"1.23, 1.45, 1.67",
      "total_memory":"63.00 GB","used_memory":"45.30 GB","free_memory":"17.70 GB",
      "memory_usage":"71.90%","jane_version":"0.1.0"
    },
    "unmonitored": ["legacy"],
    "config": {"defaults": {"cycle": 10}}
  }
  JSON
end

# Encode a report the way the agent puts it on the wire: JSON string, then
# msgpack-encode that string (jane/src/daemon.cr `data.to_msgpack`).
def wire_bytes(json : String) : Bytes
  json.to_msgpack
end

describe JaneHQ::Processor do
  it "decodes the agent's msgpack-wrapped JSON into a Payload" do
    payload = JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01", "alert")))

    payload.metrics.hostname.should eq "web-01"
    payload.metrics.cpu_cores.should eq 16
    payload.checks.size.should eq 3
    payload.alert_count.should eq 1
    payload.unmonitored.should eq ["legacy"]
  end
end

describe JaneHQ::Storage do
  it "persists a report as an agent row with a denormalized alert_count" do
    with_storage do |storage|
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01", "alert"))))

      agent = storage.agent_by_hostname("web-01").not_nil!
      agent.hostname.should eq "web-01"
      agent.alert_count.should eq 1
      agent.check_count.should eq 3
      storage.checks_for(agent.id).size.should eq 3
    end
  end

  it "orders agents by alert severity (most alerts first)" do
    with_storage do |storage|
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("quiet", "ok"))))
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("noisy", "alert"))))

      storage.all_agents.map(&.hostname).should eq ["noisy", "quiet"]
    end
  end

  it "replaces an agent's checks on a re-report (latest snapshot only)" do
    with_storage do |storage|
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01", "alert"))))
      first = storage.agent_by_hostname("web-01").not_nil!
      first.alert_count.should eq 1

      # Same host reports again, now healthy.
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01", "ok"))))

      again = storage.agent_by_hostname("web-01").not_nil!
      again.id.should eq first.id # upsert, not a new row
      again.alert_count.should eq 0
      storage.checks_for(again.id).size.should eq 3 # replaced, not appended
      storage.all_agents.size.should eq 1
    end
  end

  it "marks an agent stale once it exceeds the staleness window" do
    with_storage do |storage|
      old = Time.utc.to_unix - 120
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01"))), now: old)

      agent = storage.agent_by_hostname("web-01").not_nil!
      agent.stale?(30).should be_true
      agent.stale?(300).should be_false
    end
  end
end

describe "host groups" do
  it "seeds a default \"All Hosts\" group that means every agent" do
    with_storage do |storage|
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01"))))
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("db-01"))))

      groups = storage.all_groups
      groups.size.should eq 1
      groups.first.name.should eq JaneHQ::Storage::DEFAULT_GROUP_NAME
      groups.first.default.should be_true

      # Implicit membership: no rows, but every agent shows.
      storage.group_hostnames(groups.first.id).should be_empty
      storage.agents_in_group(groups.first).map(&.hostname).sort.should eq ["db-01", "web-01"]
    end
  end

  it "returns only the member hosts of a created group, in severity order" do
    with_storage do |storage|
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("prod-quiet", "ok"))))
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("prod-noisy", "alert"))))
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("uat-01"))))

      id = storage.create_group("Prod", ["prod-quiet", "prod-noisy"])
      group = storage.group_by_id(id).not_nil!

      group.name.should eq "Prod"
      group.default.should be_false
      group.member_count.should eq 2
      storage.agents_in_group(group).map(&.hostname).should eq ["prod-noisy", "prod-quiet"]
      storage.all_groups.map(&.name).should eq [JaneHQ::Storage::DEFAULT_GROUP_NAME, "Prod"]
    end
  end

  it "replaces membership on update and leaves agents alone on delete" do
    with_storage do |storage|
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01"))))
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("db-01"))))

      id = storage.create_group("Prod", ["web-01"])
      storage.update_group(id, "Production", ["db-01"])

      group = storage.group_by_id(id).not_nil!
      group.name.should eq "Production"
      storage.group_hostnames(id).should eq ["db-01"]

      storage.delete_group(id)
      storage.group_by_id(id).should be_nil
      storage.all_agents.size.should eq 2
    end
  end

  it "refuses to delete or rename the default group" do
    with_storage do |storage|
      default = storage.default_group

      storage.delete_group(default.id)
      storage.update_group(default.id, "Renamed", [] of String)

      storage.default_group.name.should eq JaneHQ::Storage::DEFAULT_GROUP_NAME
      storage.all_groups.size.should eq 1
    end
  end
end

describe JaneHQ::AlertRules do
  it "maps the agent's check names onto event families" do
    map = {
      "CPU Usage"                         => "cpu_usage",
      "CPU IO Wait"                       => "cpu_io_wait",
      "Load Avg (5min)"                   => "load_average",
      "Memory Usage"                      => "memory_usage",
      "Filesystem root"                   => "filesystem_space",
      "Network Interface em1 (em1 iface)" => "network_interface",
      "Network Connection phoebe"         => "network_connection",
      "Bandwidth uplink"                  => "bandwidth",
      "Process nginx"                     => "process",
      "File hosts"                        => "file_existence",
      "File hosts user"                   => "file_uid",
      "File hosts group"                  => "file_gid",
      "File hosts mode"                   => "file_permission",
    }
    map.each do |name, event|
      JaneHQ::AlertRules.event_for(name).should eq event
    end

    JaneHQ::AlertRules.event_for("Something Else").should be_nil
  end

  it "drops unknown picker values and keeps catalog order" do
    JaneHQ::AlertRules.known_statuses(["changed", "bogus", "failed"])
      .should eq ["failed", "changed"]
    JaneHQ::AlertRules.known_events(["process", "nope"]).should eq ["process"]
  end
end

describe "alert groups" do
  it "stores a rule with its targets, conditions and action" do
    with_storage do |storage|
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01"))))
      prod = storage.create_group("Prod", ["web-01"])

      id = storage.create_alert_group(
        "Trading alert",
        [JaneHQ::AlertTarget.host("web-01"), JaneHQ::AlertTarget.new("group", prod.to_s)],
        ["Filesystem root"],
        ["failed", "changed"],
        ["filesystem_space"],
        "email",
        "qbalerts@example.com",
      )

      rule = storage.alert_group_by_id(id).not_nil!
      rule.name.should eq "Trading alert"
      rule.enabled.should be_true
      rule.services.should eq ["Filesystem root"]
      rule.statuses.should eq ["failed", "changed"]
      rule.events.should eq ["filesystem_space"]
      rule.alert_type_label.should eq "Send email"
      rule.alert_target.should eq "qbalerts@example.com"

      # Host groups sort first and carry their current name.
      storage.alert_group_targets(id).map(&.display)
        .should eq ["Hostgroup Prod", "web-01"]
    end
  end

  it "treats empty service, state and event lists as \"any\"" do
    with_storage do |storage|
      id = storage.create_alert_group("Everything", [JaneHQ::AlertTarget.host("web-01")],
        [] of String, [] of String, [] of String, "slack", "https://hooks.slack.com/x")

      rule = storage.alert_group_by_id(id).not_nil!
      rule.service_summary.should eq "Any Service"
      rule.status_summary.should eq "Any State"
      rule.event_summary.should eq "Any Event"
    end
  end

  it "replaces targets and conditions on update, and toggles enabled" do
    with_storage do |storage|
      id = storage.create_alert_group("Rule", [JaneHQ::AlertTarget.host("web-01")],
        [] of String, ["failed"], [] of String, "email", "a@example.com")

      storage.update_alert_group(id, "Renamed", [JaneHQ::AlertTarget.host("db-01")],
        ["CPU Usage"], ["succeeded"], ["cpu_usage"], "exec", "/bin/true", false)

      rule = storage.alert_group_by_id(id).not_nil!
      rule.name.should eq "Renamed"
      rule.enabled.should be_false
      rule.services.should eq ["CPU Usage"]
      rule.statuses.should eq ["succeeded"]
      storage.alert_group_targets(id).map(&.ref).should eq ["db-01"]

      storage.set_alert_group_enabled(id, true)
      storage.alert_group_by_id(id).not_nil!.enabled.should be_true

      storage.delete_alert_group(id)
      storage.alert_group_by_id(id).should be_nil
      storage.alert_group_targets(id).should be_empty
    end
  end

  it "drops a deleted host group from the rules that watched it" do
    with_storage do |storage|
      prod = storage.create_group("Prod", ["web-01"])
      id = storage.create_alert_group("Rule",
        [JaneHQ::AlertTarget.new("group", prod.to_s), JaneHQ::AlertTarget.host("web-01")],
        [] of String, ["failed"], [] of String, "email", "a@example.com")

      storage.delete_group(prod)

      storage.alert_group_targets(id).map(&.ref).should eq ["web-01"]
    end
  end

  it "keeps rules watching the default host group, which cannot be deleted" do
    with_storage do |storage|
      default = storage.default_group
      id = storage.create_alert_group("Rule",
        [JaneHQ::AlertTarget.new("group", default.id.to_s)],
        [] of String, ["failed"], [] of String, "email", "a@example.com")

      storage.delete_group(default.id)

      storage.alert_group_targets(id).map(&.display)
        .should eq ["Hostgroup #{JaneHQ::Storage::DEFAULT_GROUP_NAME}"]
    end
  end

  it "offers every reported check name as a service choice" do
    with_storage do |storage|
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01"))))
      storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("db-01"))))

      storage.distinct_check_names.should eq ["CPU Usage", "Filesystem root", "Memory Usage"]
    end
  end
end

# Runs the block with a Storage backed by a throwaway on-disk SQLite file.
def with_storage(&)
  path = File.tempname("janehq_spec", ".db")
  storage = JaneHQ::Storage.new(path)
  begin
    yield storage
  ensure
    storage.close
    File.delete(path) if File.exists?(path)
    File.delete("#{path}-wal") if File.exists?("#{path}-wal")
    File.delete("#{path}-shm") if File.exists?("#{path}-shm")
  end
end

require "../src/ago"

describe "JaneHQ.ago" do
  it "scales units" do
    JaneHQ.ago(8).should eq "8s"
    JaneHQ.ago(60).should eq "60s"
    JaneHQ.ago(200).should eq "3 min"
    JaneHQ.ago(40 * 60).should eq "40 min"
    JaneHQ.ago(3 * 3600 + 120).should eq "3 hours 2 min"
    JaneHQ.ago(2 * 86400 + 12 * 3600 + 30 * 60).should eq "2 days 12 hours 30 min"
  end
end

require "../src/alerts/notifier"

def alert_report(host : String, fs_status : String = "alert")
  JaneHQ::Processor.decode(wire_bytes(sample_report_json(host, fs_status)))
end

def make_slack_rule(storage, targets, url, count = "once", freq = 5, services = [] of String)
  storage.create_alert_group("slack rule #{Random.rand(1_000_000)}", targets, services, ["failed"], [] of String,
    "slack", url, count, freq)
end

# Slack notifier: one pooled message per webhook, at most one per minute.
describe JaneHQ::Notifier do
  url = "https://hooks.slack.com/services/T/B/X"

  it "pools alerts from several hosts into a single message" do
    with_storage do |storage|
      storage.persist(alert_report("web-01"))
      storage.persist(alert_report("db-01"))
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01"), JaneHQ::AlertTarget.host("db-01")], url)

      bodies = [] of String
      n = JaneHQ::Notifier.new(storage, 30, ->(_u : String, b : String) { bodies << b; true })
      n.tick(Time.utc.to_unix)

      bodies.size.should eq 1
      bodies[0].should contain "2 alerts on 2 hosts"
      bodies[0].should contain "web-01"
      bodies[0].should contain "db-01"
    end
  end

  it "mutes an acknowledged alert until the ack lapses, then notifies again" do
    with_storage do |storage|
      storage.persist(alert_report("web-01"))
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01")], url)
      now = Time.utc.to_unix
      names = storage.alert_checks_for(storage.agent_by_hostname("web-01").not_nil!.id).map(&.name)
      storage.ack_alerts("web-01", names, now + 3600, now)

      count = 0
      n = JaneHQ::Notifier.new(storage, 100_000, ->(_u : String, _b : String) { count += 1; true })
      n.tick(now)
      n.tick(now + 120)
      count.should eq 0 # acked

      n.tick(now + 3601) # ack lapsed, still failing -> notifies as new
      count.should eq 1
      storage.all_acks.should be_empty
    end
  end

  it "waits out the batch window so hosts failing moments apart share one message" do
    with_storage do |storage|
      now = Time.utc.to_unix
      storage.persist(alert_report("web-01"), now)
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01"), JaneHQ::AlertTarget.host("db-01")], url)

      bodies = [] of String
      n = JaneHQ::Notifier.new(storage, 100_000, ->(_u : String, b : String) { bodies << b; true }, batch_window: 30_i64)
      n.tick(now)
      bodies.should be_empty # held back
      storage.persist(alert_report("db-01"), now + 10)
      n.tick(now + 10)
      bodies.should be_empty
      n.tick(now + 30)
      bodies.size.should eq 1
      bodies[0].should contain "2 alerts on 2 hosts"
    end
  end

  it "does not re-send a 'once' alert, and alerts again after recovery" do
    with_storage do |storage|
      storage.persist(alert_report("web-01"))
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01")], url)

      count = 0
      n = JaneHQ::Notifier.new(storage, 100_000, ->(_u : String, _b : String) { count += 1; true })
      now = Time.utc.to_unix
      n.tick(now)
      n.tick(now + 120)
      count.should eq 1

      storage.persist(alert_report("web-01", "ok"), now + 130)
      n.tick(now + 140) # recovered, but inside the 5 min grace: still remembered
      storage.persist(alert_report("web-01"), now + 200)
      n.tick(now + 210) # quick relapse = same episode, no new alert
      count.should eq 1
      storage.persist(alert_report("web-01", "ok"), now + 220)
      n.tick(now + 230)
      n.tick(now + 600) # clear for > 5 min -> forgotten
      storage.persist(alert_report("web-01"), now + 610)
      n.tick(now + 620)
      count.should eq 2
    end
  end

  it "sends to a webhook at most once per minute, queueing alerts until the gap passes" do
    with_storage do |storage|
      storage.persist(alert_report("web-01"))
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01"), JaneHQ::AlertTarget.host("db-01")], url)

      bodies = [] of String
      n = JaneHQ::Notifier.new(storage, 100_000, ->(_u : String, b : String) { bodies << b; true })
      now = Time.utc.to_unix
      n.tick(now)
      storage.persist(alert_report("db-01"), now + 5)
      n.tick(now + 10) # db-01 is due, but inside the 60s gap
      bodies.size.should eq 1
      n.tick(now + 60)
      bodies.size.should eq 2
      bodies[1].should contain "db-01"
      bodies[1].should_not contain "web-01"
    end
  end

  it "re-sends a recurring alert after its frequency and retries a failed post" do
    with_storage do |storage|
      storage.persist(alert_report("web-01"))
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01")], url, "recurring", 3)

      results = [false, true, true]
      calls = 0
      n = JaneHQ::Notifier.new(storage, 100_000, ->(_u : String, _b : String) { calls += 1; results.shift })
      now = Time.utc.to_unix
      n.tick(now)      # post fails
      n.tick(now + 30) # inside gap
      calls.should eq 1
      n.tick(now + 60) # retry succeeds
      calls.should eq 2
      n.tick(now + 120) # recurring 3 min not elapsed
      calls.should eq 2
      n.tick(now + 60 + 180)
      calls.should eq 3
    end
  end

  it "alerts for an offline host" do
    with_storage do |storage|
      now = Time.utc.to_unix
      storage.persist(alert_report("web-01", "ok"), now - 100)
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01")], url)

      bodies = [] of String
      n = JaneHQ::Notifier.new(storage, 30, ->(_u : String, b : String) { bodies << b; true })
      n.tick(now)
      bodies.size.should eq 1
      bodies[0].should contain "Host offline"
    end
  end
end

describe JaneHQ::Slack do
  it "escapes mrkdwn control characters and caps blocks at 50" do
    alerts = (1..300).map { |i| JaneHQ::Alert.new("h#{i}", "Check <x>", "a & b") }
    json = JaneHQ::Slack.payload(alerts)
    parsed = JSON.parse(json)
    parsed["blocks"].as_a.size.should be <= 50
    json.should contain "&lt;x&gt;"
    json.should contain "more hosts not shown"
  end
end

describe "Slack host links" do
  it "links each host to its JaneHQ page when a base URL is set" do
    alerts = [JaneHQ::Alert.new("web 01", "CPU Usage", "hot")]
    json = JaneHQ::Slack.payload(alerts, "https://hq.example.com")
    json.should contain "<https://hq.example.com/agent/web%2001|*web 01*>"
    JaneHQ::Slack.payload(alerts).should_not contain "/agent/"
  end
end

describe "alert delivery edge cases" do
  url = "https://hooks.slack.com/services/T/B/X"

  it "does not re-alert a flapping check inside the rule's interval" do
    with_storage do |storage|
      now = Time.utc.to_unix
      storage.persist(alert_report("web-01"), now)
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01")], url, "recurring", 10)

      count = 0
      n = JaneHQ::Notifier.new(storage, 100_000, ->(_u : String, _b : String) { count += 1; true })
      n.tick(now)
      count.should eq 1
      # fails, recovers, fails again, every minute for 9 minutes
      (1..9).each do |m|
        storage.persist(alert_report("web-01", m.odd? ? "ok" : "alert"), now + m * 60)
        n.tick(now + m * 60)
      end
      count.should eq 1
      storage.persist(alert_report("web-01"), now + 600)
      n.tick(now + 600)
      count.should eq 2
    end
  end

  it "picks up rule edits on the next tick without a restart" do
    with_storage do |storage|
      now = Time.utc.to_unix
      storage.persist(alert_report("web-01"), now)
      id = make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01")], url, "recurring", 60)

      count = 0
      n = JaneHQ::Notifier.new(storage, 100_000, ->(_u : String, _b : String) { count += 1; true })
      n.tick(now)
      n.tick(now + 120)
      count.should eq 1
      storage.update_alert_group(id, "slack rule", [JaneHQ::AlertTarget.host("web-01")],
        [] of String, ["failed"], [] of String, "slack", url, true, "recurring", 1)
      n.tick(now + 130)
      count.should eq 2
    end
  end

  it "validates webhook URLs" do
    JaneHQ::AlertRules.webhook_url?("https://hooks.slack.com/services/T/B/X").should be_true
    ["sfdfdfd", "http://hooks.slack.com/x", "https://", "https://localhost/x", "https://a b.com/x", ""].each do |bad|
      JaneHQ::AlertRules.webhook_url?(bad).should be_false
    end
  end
end

describe "recurring alert consolidation" do
  it "sends one message with every active alert when any recurring alert is due" do
    with_storage do |storage|
      url = "https://hooks.slack.com/services/T/B/X"
      now = Time.utc.to_unix
      storage.persist(alert_report("web-01"), now)
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01"), JaneHQ::AlertTarget.host("db-01")], url, "recurring", 5)
      bodies = [] of String
      n = JaneHQ::Notifier.new(storage, 100_000, ->(_u : String, b : String) { bodies << b; true })
      n.tick(now)
      storage.persist(alert_report("db-01"), now + 100)
      n.tick(now + 100) # db-01 is new, web-01 is not yet due again
      bodies.size.should eq 2
      bodies[1].should contain "web-01"
      bodies[1].should contain "db-01"
      n.tick(now + 100 + 300) # both share one schedule now
      bodies.size.should eq 3
      bodies[2].should contain "2 alerts on 2 hosts"
    end
  end
end

describe "hosts in several alert groups" do
  prod = "https://hooks.slack.com/services/T/B/PROD"
  test = "https://hooks.slack.com/services/T/B/TEST"

  it "with different webhooks, each channel gets the alert on its own group's schedule" do
    with_storage do |storage|
      now = Time.utc.to_unix
      storage.persist(alert_report("web-01"), now)
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01")], test, "recurring", 3)
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01")], prod, "recurring", 1)

      sent = [] of String
      n = JaneHQ::Notifier.new(storage, 100_000, ->(u : String, _b : String) { sent << u; true })
      n.tick(now)
      sent.sort.should eq [prod, test]
      sent.clear
      n.tick(now + 60)
      sent.should eq [prod]
      n.tick(now + 180)
      sent.sort.should eq [prod, prod, test]
    end
  end

  it "with the same webhook, sends once at the shortest frequency" do
    with_storage do |storage|
      now = Time.utc.to_unix
      storage.persist(alert_report("web-01"), now)
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01")], prod, "recurring", 3)
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01")], prod, "recurring", 1)

      sent = 0
      n = JaneHQ::Notifier.new(storage, 100_000, ->(_u : String, _b : String) { sent += 1; true })
      n.tick(now)
      n.tick(now + 60)
      n.tick(now + 120)
      sent.should eq 3
    end
  end

  it "sends two hosts of one group as a single message each interval" do
    with_storage do |storage|
      now = Time.utc.to_unix
      storage.persist(alert_report("web-01"), now)
      storage.persist(alert_report("db-01"), now)
      make_slack_rule(storage, [JaneHQ::AlertTarget.host("web-01"), JaneHQ::AlertTarget.host("db-01")], prod, "recurring", 2)

      bodies = [] of String
      n = JaneHQ::Notifier.new(storage, 100_000, ->(_u : String, b : String) { bodies << b; true })
      n.tick(now)
      n.tick(now + 119)
      bodies.size.should eq 1
      n.tick(now + 120)
      bodies.size.should eq 2
      bodies[1].should contain "2 alerts on 2 hosts"
    end
  end
end

describe "metric time series" do
  it "buckets reports per minute, rolls up to hours, and serves a series" do
    storage = JaneHQ::Storage.new(":memory:")
    base = 1_700_000_000_i64 - 1_700_000_000_i64 % 3600                          # hour-aligned
    payload = JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01"))) # cpu 8.45, mem 71.9, load 1.23
    3.times { |i| storage.persist(payload, base + i * 10) }                      # same minute
    storage.persist(payload, base + 60)
    id = storage.agent_by_hostname("web-01").not_nil!.id

    pts = storage.metric_series(id, base, base + 3599, now: base + 3600)
    pts.size.should eq 2
    pts[0].cpu_avg.should be_close(8.45, 0.001)
    pts[0].mem_max.should be_close(71.9, 0.001)
    pts[0].load1.should be_close(1.23, 0.001)

    storage.rollup_metrics!(base + 3600 + 8 * 86_400) # minutes now past retention
    storage.metric_series(id, base, base + 3599, now: base + 3600 + 8 * 86_400).size.should eq 1
  end
end

describe "metrics retention" do
  it "deletes hourly and minute rows older than the retention window" do
    storage = JaneHQ::Storage.new(":memory:")
    base = 1_700_000_000_i64 - 1_700_000_000_i64 % 3600
    storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01"))), base)
    id = storage.agent_by_hostname("web-01").not_nil!.id
    now = base + 3600 + 10 * 86_400
    storage.rollup_metrics!(now, 360)
    storage.metric_series(id, base, base + 3599, now: now).size.should eq 1 # hourly row kept
    now = base + 3600 + 11 * 86_400
    storage.rollup_metrics!(now, 10)
    storage.metric_series(id, base, base + 3599, now: now).size.should eq 0
  end

  it "parses JANEHQ_METRICS_RETENTION" do
    JaneHQ::Config.parse_retention(nil).should eq 360
    JaneHQ::Config.parse_retention("30").should eq 30
    JaneHQ::Config.parse_retention("0").should be_nil
    JaneHQ::Config.parse_retention("abc").should be_nil
  end
end

describe "top process history" do
  it "keeps 5-minute snapshots, thins old ones to hourly, and prunes past retention" do
    storage = JaneHQ::Storage.new(":memory:")
    json = JSON.parse(sample_report_json("web-01")).as_h
    m = json["metrics"].as_h
    m["top_procs"] = JSON.parse(%({"by_memory":[{"pid":1,"name":"chrome","rss_bytes":5}],"by_cpu":[],"by_disk_io":[]}))
    json["metrics"] = JSON::Any.new(m)
    payload = JaneHQ::Processor.decode(wire_bytes(json.to_json))
    base = 1_700_000_000_i64 - 1_700_000_000_i64 % 3600
    [0, 10, 300, 600, 3600].each { |o| storage.persist(payload, base + o) } # 0/10 share a bucket
    id = storage.agent_by_hostname("web-01").not_nil!.id
    storage.top_procs_at(id, base + 299).not_nil![1].should eq base
    storage.top_procs_at(id, base + 700).not_nil![1].should eq base + 600
    storage.top_procs_at(id, base - 1).should be_nil
    storage.rollup_metrics!(base + 8 * 86_400, 360) # past the 5-minute tier: one per hour
    storage.top_procs_at(id, base + 700).not_nil![1].should eq base
    storage.top_procs_at(id, base + 3700).not_nil![1].should eq base + 3600
    storage.rollup_metrics!(base + 3600 + 10 * 86_400, 10) # past retention
    storage.top_procs_at(id, base + 3700).not_nil![1].should eq base + 3600
    storage.rollup_metrics!(base + 3601 + 10 * 86_400, 10)
    storage.top_procs_at(id, base + 3700).should be_nil
  end
end

describe "top processes" do
  it "ingests top_procs (I/O fields optional), keeps the latest snapshot, tolerates older agents" do
    storage = JaneHQ::Storage.new(":memory:")
    json = JSON.parse(sample_report_json("web-01")).as_h
    m = json["metrics"].as_h
    m["top_procs"] = JSON.parse(%({"by_memory":[{"pid":1,"name":"chrome","cpu_pct":0.5,"rss_bytes":1133727744,"io_read_bps":0.0,"io_write_bps":31009.8},{"pid":2,"name":"Xorg","cpu_pct":0.1,"rss_bytes":373948416}],"by_cpu":[],"by_disk_io":[{"pid":3,"name":"janehq","cpu_pct":0.0,"rss_bytes":1,"io_write_bps":138600.6}]}))
    json["metrics"] = JSON::Any.new(m)
    storage.persist(JaneHQ::Payload.from_json(json.to_json))
    id = storage.agent_by_hostname("web-01").not_nil!.id

    top, _ = storage.top_procs_for(id).not_nil!
    top.by_memory.map(&.name).should eq ["chrome", "Xorg"]
    top.by_memory[1].io_write_bps.should be_nil
    top.by_disk_io[0].io_bps.should be_close(138600.6, 0.01)

    # an older agent (no top_procs) leaves the last snapshot in place
    storage.persist(JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01"))))
    storage.top_procs_for(id).should_not be_nil
    storage.top_procs_for(id + 99).should be_nil
  end
end

describe "swap metric" do
  it "is recorded from the Swap Usage check, survives rollup, and is nil without it" do
    storage = JaneHQ::Storage.new(":memory:")
    base = 1_700_000_000_i64 - 1_700_000_000_i64 % 3600
    plain = JaneHQ::Processor.decode(wire_bytes(sample_report_json("web-01")))
    storage.persist(plain, base)
    id = storage.agent_by_hostname("web-01").not_nil!.id
    storage.metric_series(id, base, base + 3599, now: base + 3600)[0].swap_avg.should be_nil

    json = JSON.parse(sample_report_json("web-01")).as_h
    json["checks"] = JSON.parse(%([{"name":"Swap Usage","status":"ok","current":"12.50%","threshold":"50%","message":"Within limits"}]))
    swappy = JaneHQ::Payload.from_json(json.to_json)
    storage.persist(swappy, base + 60)
    storage.persist(swappy, base + 120)
    pts = storage.metric_series(id, base + 60, base + 3599, now: base + 3600)
    pts[0].swap_avg.not_nil!.should be_close(12.5, 0.001)
    pts[0].swap_max.not_nil!.should be_close(12.5, 0.001)

    storage.rollup_metrics!(base + 3600 + 8 * 86_400)
    storage.metric_series(id, base, base + 3599, now: base + 3600 + 8 * 86_400)[0].swap_avg.not_nil!.should be_close(12.5, 0.001)
  end
end

describe "user prefs" do
  it "stores and overwrites a per-user value" do
    storage = JaneHQ::Storage.new(":memory:")
    storage.pref("admin", "dashboard_group").should be_nil
    storage.set_pref("admin", "dashboard_group", "3")
    storage.set_pref("admin", "dashboard_group", "4")
    storage.pref("admin", "dashboard_group").should eq "4"
    storage.pref("other", "dashboard_group").should be_nil
  end
end

describe "users" do
  it "generates 15-40 character passwords" do
    lens = Array.new(200) { JaneHQ::Passwords.generate.size }
    lens.min.should be >= 15
    lens.max.should be <= 40
    JaneHQ::Passwords.generate.should_not eq JaneHQ::Passwords.generate
  end

  it "creates, authenticates, and protects users" do
    storage = JaneHQ::Storage.new(":memory:")
    id = storage.create_user("superjane", "temp-password-123", JaneHQ::Role::SUPERUSER, temp: true)
    storage.temp_password_users.should eq ["superjane"]
    user = storage.user_by_name("SuperJane").not_nil! # case-insensitive
    JaneHQ::Passwords.verify?("temp-password-123", user.password_hash).should be_true
    JaneHQ::Passwords.verify?("wrong", user.password_hash).should be_false

    storage.set_user_password(id, "a-new-password-456")
    storage.temp_password_users.should be_empty
    storage.superuser_count.should eq 1
    JaneHQ::Role.can_write?(JaneHQ::Role::READ_ONLY).should be_false
    JaneHQ::Role.can_write?(JaneHQ::Role::STAFF).should be_true
  end
end

describe "google sign-in" do
  config = JaneHQ::Config.new("admin", nil, 80, 25900, ":memory:", "s", 30, nil,
    "cid", "secret", "example.com")

  token = ->(claims : Hash(String, String | Int64 | Bool)) do
    "x.#{Base64.urlsafe_encode(claims.to_json, padding: false)}.y"
  end
  good = {"iss" => "https://accounts.google.com", "aud" => "cid", "exp" => 2_000_000_000_i64,
          "sub" => "123", "email" => "Jo@Example.com", "email_verified" => true, "hd" => "example.com"}

  it "is only enabled when client id, secret and domain are all set" do
    mk = ->(id : String?, sec : String?, dom : String?) {
      JaneHQ::Config.new("a", nil, 80, 25900, ":memory:", "s", 30, nil, id, sec, dom)
    }
    mk.call("cid", "sec", "example.com").google_enabled?.should be_true
    mk.call("cid", "sec", nil).google_enabled?.should be_false
    mk.call("cid", "sec", nil).google_partial?.should be_true
    mk.call(nil, nil, nil).google_partial?.should be_false
  end

  it "fails closed when no domain is configured" do
    open = JaneHQ::Config.new("a", nil, 80, 25900, ":memory:", "s", 30, nil, "cid", "secret", nil)
    expect_raises(JaneHQ::Google::Error) { JaneHQ::Google.identity(open, token.call(good), 1_000_i64) }
  end

  it "accepts a valid token and lowercases the email" do
    id = JaneHQ::Google.identity(config, token.call(good), 1_000_i64)
    id.email.should eq "jo@example.com"
    id.sub.should eq "123"
  end

  it "rejects wrong audience, unverified email, expired, and other domains" do
    {
      good.merge({"aud" => "other"}),
      good.merge({"email_verified" => false}),
      good.merge({"exp" => 5_i64}),
      good.merge({"hd" => "evil.com", "email" => "a@evil.com"}),
      good.merge({"hd" => "example.com", "email" => "a@evil.com"}),
    }.each do |claims|
      expect_raises(JaneHQ::Google::Error) { JaneHQ::Google.identity(config, token.call(claims), 1_000_i64) }
    end
  end

  it "creates a read_only local user once, which cannot use password login" do
    storage = JaneHQ::Storage.new(":memory:")
    id = JaneHQ::Google::Identity.new("123", "jo@example.com")
    user = JaneHQ::Google.find_or_create_user(storage, id).not_nil!
    user.role.should eq JaneHQ::Role::READ_ONLY
    user.google?.should be_true
    JaneHQ::Google.find_or_create_user(storage, id).not_nil!.id.should eq user.id
    storage.user_count.should eq 1
    JaneHQ::Passwords.verify?("", user.password_hash).should be_false
    storage.set_user_role(user.id, JaneHQ::Role::STAFF)
    JaneHQ::Google.find_or_create_user(storage, id).not_nil!.role.should eq JaneHQ::Role::STAFF
  end
end

describe "JaneHQ.reset_superuser" do
  it "creates superjane when missing, then resets password, role and enabled flag" do
    st = JaneHQ::Storage.new(":memory:")
    JaneHQ.reset_superuser(st).should be_true
    u = st.user_by_name("superjane").not_nil!
    u.role.should eq JaneHQ::Role::SUPERUSER
    u.temp_password.should be_true

    st.set_user_disabled(u.id, true)
    st.set_user_role(u.id, JaneHQ::Role::READ_ONLY)
    old = u.password_hash
    JaneHQ.reset_superuser(st).should be_true
    u = st.user_by_name("superjane").not_nil!
    u.password_hash.should_not eq old
    u.disabled.should be_false
    u.role.should eq JaneHQ::Role::SUPERUSER
    st.user_count.should eq 1
  end
end
