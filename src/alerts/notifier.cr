require "log"
require "../storage"
require "./slack"

module JaneHQ
  # Evaluates every enabled Slack alert group against the latest agent state
  # and delivers what is due. Runs as its own fiber (not inline in ingest) so
  # rate limiting and pooling are in one place.
  #
  # Rules:
  #  * An alert is a failing check, or a host that stopped reporting.
  #  * A rule re-sends a still-failing alert only if it is "recurring" and its
  #    frequency has elapsed; "once" alerts fire once per failure episode
  #    (state is cleared when the check recovers).
  #  * Everything due for one webhook URL goes out in a single message, and a
  #    given URL is posted to at most once per MIN_GAP seconds. A failed post
  #    is retried after the gap.
  class Notifier
    Log = ::Log.for("notifier")

    TICK    = 10.seconds
    MIN_GAP = 60_i64

    # How long an alert must stay clear before it counts as recovered.
    RECOVERY_GRACE = 300_i64

    alias Poster = Proc(String, String, Bool)

    private record Due, rule_id : Int64, alert : Alert

    def initialize(@storage : Storage, @stale_after : Int32,
                   @poster : Poster = ->(url : String, body : String) { Slack.post(url, body) },
                   @base_url : String? = nil)
      @last_post = {} of String => Int64
      @warned = Set({Int64, String}).new
    end

    def run
      loop do
        begin
          tick
        rescue ex
          Log.error(exception: ex) { "notifier tick failed" }
        end
        sleep TICK
      end
    end

    def tick(now : Int64 = Time.utc.to_unix)
      agents = @storage.all_agents.to_h { |a| {a.hostname, a} }
      by_url = {} of String => Array(Due)

      @storage.all_alert_groups.each do |rule|
        next unless rule.enabled && rule.alert_type == "slack"
        url = rule.alert_target
        next if url.blank?
        unless AlertRules.webhook_url?(url)
          Log.warn { "alert group #{rule.name.inspect}: #{url.inspect} is not a valid webhook URL (needs https://...); skipping" } if @warned.add?({rule.id, url})
          next
        end

        hosts = @storage.alert_group_targets(rule.id)
          .flat_map { |t| @storage.target_hostnames(t) }.uniq
        states = @storage.alert_states(rule.id)
        active = Set({String, String}).new

        hosts.each do |host|
          agent = agents[host]?
          next if agent.nil?
          alerts_for(rule, agent, now).each do |alert|
            key = {alert.hostname, alert.check}
            active << key
            state = states[key]?
            @storage.touch_alert_active(rule.id, alert.hostname, alert.check, now) if state
            recurring_due = rule.alert_count == "recurring" && state &&
                            now - state.last_sent_at >= rule.alert_frequency_minutes.to_i64 * 60
            (by_url[url] ||= [] of Due) << Due.new(rule.id, alert) if state.nil? || recurring_due
          end
        end

        # Forget an alert only once it has stayed away for a while. Forgetting
        # at the first recovery would let a flapping check (e.g. CPU I/O wait
        # hovering at its limit) start a "new" alert every minute and ignore
        # the rule's frequency. A recurring rule keeps its memory for at least
        # its own interval.
        grace = RECOVERY_GRACE
        grace = {grace, rule.alert_frequency_minutes.to_i64 * 60}.max if rule.alert_count == "recurring"
        states.each do |key, state|
          next if active.includes?(key)
          @storage.clear_alert_state(rule.id, key[0], key[1]) if now - state.last_active_at >= grace
        end
      end

      by_url.each { |url, dues| deliver(url, dues, now) }
    end

    private def deliver(url : String, dues : Array(Due), now : Int64)
      last = @last_post[url]?
      return if last && now - last < MIN_GAP

      alerts = dues.map(&.alert).uniq { |a| {a.hostname, a.check} }
      @last_post[url] = now # counts failed attempts too: never faster than MIN_GAP
      if @poster.call(url, Slack.payload(alerts, @base_url))
        dues.each { |d| @storage.mark_alert_sent(d.rule_id, d.alert.hostname, d.alert.check, now) }
        Log.info { "sent #{alerts.size} alert(s) for #{alerts.map(&.hostname).uniq.size} host(s) to slack" }
      end
    end

    # The alerts a rule currently sees on one host. A stale host yields only
    # the offline alert (its stored checks are out of date).
    private def alerts_for(rule : AlertGroupRecord, agent : AgentRecord, now : Int64) : Array(Alert)
      # Slack alerts are only about problems: Failed, or Changed (a check
      # newly failing). A rule limited to Succeeded never matches.
      return [] of Alert unless rule.statuses.empty? || rule.statuses.includes?("failed") || rule.statuses.includes?("changed")

      if agent.stale?(@stale_after, now)
        return [] of Alert unless rule.services.empty? && rule.events.empty?
        return [Alert.new(agent.hostname, Alert::OFFLINE, "no report for #{now - agent.last_seen}s")]
      end

      @storage.alert_checks_for(agent.id).compact_map do |c|
        next unless rule.services.empty? || rule.services.includes?(c.name)
        next unless rule.events.empty? || rule.events.includes?(AlertRules.event_for(c.name))
        Alert.new(agent.hostname, c.name, detail(c))
      end
    end

    private def detail(c : CheckRecord) : String
      # "26.67% (limit 2.00%)". The agent's message mostly repeats the check
      # name ("CPU usage exceeds limit"), so it is kept only when there is no
      # value to show, or the value is just "error" (the message is the news).
      parts = [] of String
      parts << c.current unless c.current.blank?
      parts << "(limit #{c.threshold})" unless c.threshold.blank?
      parts << c.message if (c.current.blank? || c.current == "error") && !c.message.blank?
      parts.join(' ')
    end
  end
end
