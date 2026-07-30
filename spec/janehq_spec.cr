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
