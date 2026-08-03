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
