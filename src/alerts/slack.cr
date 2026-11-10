require "json"
require "http/client"
require "log"

module JaneHQ
  # One alert to deliver: a failing check on a host, or the host itself
  # going offline (check = Alert::OFFLINE).
  record Alert, hostname : String, check : String, detail : String do
    OFFLINE = "Host offline"
  end

  # Builds and posts Slack incoming-webhook messages. Many alerts across many
  # hosts are pooled into ONE message: a header plus one section per host.
  module Slack
    Log = ::Log.for("slack")

    # Slack allows 50 blocks per message and 3000 chars per section text.
    MAX_BLOCKS        =   50
    MAX_SECTION_CHARS = 3000

    # Keeps one alert to a single line in Slack.
    MAX_DETAIL_CHARS = 80

    def self.truncate(text : String, max : Int32) : String
      text.size > max ? "#{text[0, max - 1]}…" : text
    end

    # Slack mrkdwn only needs these three escaped.
    def self.escape(text : String) : String
      text.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;")
    end

    def self.line(alert : Alert) : String
      detail = alert.detail.blank? ? "" : " #{escape(truncate(alert.detail, MAX_DETAIL_CHARS))}"
      "• *#{escape(alert.check)}*#{detail}"
    end

    # Alerts are grouped by host (first-seen order). Overflowing hosts are
    # summarized in a trailing context block rather than silently dropped.
    def self.payload(alerts : Array(Alert), base_url : String? = nil) : String
      by_host = alerts.group_by(&.hostname)
      hosts_label = by_host.size == 1 ? "1 host" : "#{by_host.size} hosts"
      alerts_label = alerts.size == 1 ? "1 alert" : "#{alerts.size} alerts"
      title = "JaneHQ: #{alerts_label} on #{hosts_label}"

      blocks = [] of Hash(String, JSON::Any)
      blocks << block("header", {"text" => {"type" => "plain_text", "text" => title}})

      # Leave room for the header and a possible "+N more" footer.
      room = MAX_BLOCKS - 2
      by_host.first(room).each do |host, host_alerts|
        blocks << section(host, host_alerts, base_url)
      end
      hidden = by_host.size - room
      if hidden > 0
        blocks << block("context", {"elements" => [{"type" => "mrkdwn", "text" => "+#{hidden} more hosts not shown"}]})
      end

      {text: title, blocks: blocks}.to_json
    end

    private def self.section(host : String, alerts : Array(Alert), base_url : String? = nil) : Hash(String, JSON::Any)
      name = "*#{escape(host)}*"
      # Slack link syntax: <url|label>. The label is already escaped.
      name = "<#{base_url}/agent/#{URI.encode_path_segment(host)}|#{name}>" if base_url
      head = "#{name} — #{alerts.size == 1 ? "1 alert" : "#{alerts.size} alerts"}"
      text = String.build do |io|
        io << head
        alerts.each_with_index do |a, i|
          l = line(a)
          if io.bytesize + l.bytesize + 40 > MAX_SECTION_CHARS
            io << "\n_+#{alerts.size - i} more_"
            break
          end
          io << '\n' << l
        end
      end
      block("section", {"text" => {"type" => "mrkdwn", "text" => text}})
    end

    private def self.block(type : String, fields) : Hash(String, JSON::Any)
      JSON.parse({"type" => type}.merge(fields).to_json).as_h
    end

    # POSTs a payload to a webhook URL. True on a 2xx response.
    def self.post(url : String, body : String) : Bool
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 5.seconds
      client.read_timeout = 10.seconds
      response = client.post(uri.request_target, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body)
      return true if response.success?
      Log.error { "slack webhook returned #{response.status_code}: #{response.body[0, 200]}" }
      false
    rescue ex
      Log.error(exception: ex) { "slack webhook post failed" }
      false
    ensure
      client.try &.close
    end
  end
end
