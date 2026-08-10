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
