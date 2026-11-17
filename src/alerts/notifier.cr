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

    # Production wait between a webhook's first due alert and posting it, so
    # alerts from hosts that fail moments apart (agents report independently)
    # leave as one message instead of one each.
    BATCH_WINDOW = 30_i64

    # How long an alert must stay clear before it counts as recovered.
    RECOVERY_GRACE = 300_i64

    alias Poster = Proc(String, String, Bool)

    private record Due, rule_id : Int64, alert : Alert

    def initialize(@storage : Storage, @stale_after : Int32,
                   @poster : Poster = ->(url : String, body : String) { Slack.post(url, body) },
                   @base_url : String? = nil, @batch_window : Int64 = 0_i64)
      @first_due = {} of String => Int64
      @rule_ids_by_url = {} of String => Array(Int64)
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
      acked = reconcile_acks(agents, now)
      rules = deliverable_rules

      # 1. Which rules see which alert. A host can sit in several alert groups.
      seen = {} of {String, String} => {Alert, Array(AlertGroupRecord)}
      rules.each do |rule|
        hosts = @storage.alert_group_targets(rule.id)
          .flat_map { |t| @storage.target_hostnames(t) }.uniq
        hosts.each do |host|
          agent = agents[host]?
          next if agent.nil?
          alerts_for(rule, agent, now).each do |alert|
            entry = (seen[{alert.hostname, alert.check}] ||= {alert, [] of AlertGroupRecord})
            entry[1] << rule
          end
        end
      end

      # 2. Per webhook, each alert is delivered by ONE rule: the one with the
      #    shortest repeat interval ("once" rules count as never repeating;
      #    ties go to the oldest rule). Two groups sharing a webhook therefore
      #    never send the same alert twice, while groups with different
      #    webhooks (different channels) each deliver it. What was already sent
      #    is remembered per alert and webhook, whichever rule sent it.
      @rule_ids_by_url = rules.group_by(&.alert_target).transform_values(&.map(&.id))
      sent = latest_sent_states(rules)
      owned = {} of Int64 => Array(Alert)
      seen.each do |key, (alert, matching)|
        @storage.touch_alert_active_everywhere(alert.hostname, alert.check, now) if sent.keys.any? { |(_, k)| k == key }
        next if acked.includes?(key) # acknowledged: stay quiet until the ack lapses
        matching.group_by(&.alert_target).each_value do |same_url|
          owner = same_url.min_by { |r| {repeat_seconds(r), r.id} }
          (owned[owner.id] ||= [] of Alert) << alert
        end
      end

      # 3. Per owning rule: when anything is due, a recurring rule reports its
      #    whole current picture, so hosts that began failing at different
      #    moments share one message and one schedule from then on. A "once"
      #    rule sends only alerts that are new.
      by_url = {} of String => Array(Due)
      rules.each do |rule|
        pending = owned[rule.id]? || next
        interval = repeat_seconds(rule)
        due = pending.select do |a|
          st = sent[{rule.alert_target, {a.hostname, a.check}}]?
          st.nil? || now - st.last_sent_at >= interval
        end
        next if due.empty?
        send = rule.alert_count == "recurring" ? pending : due
        send.each { |a| (by_url[rule.alert_target] ||= [] of Due) << Due.new(rule.id, a) }
      end

      prune_states(rules, seen, now)

      @first_due.reject! { |url, _| !by_url.has_key?(url) } # nothing due any more: restart the window
      by_url.each do |url, dues|
        since = @first_due[url] ||= now
        deliver(url, dues, now) if now - since >= @batch_window
      end
    end

    # Enabled Slack rules with a usable webhook (bad ones are warned about once).
    private def deliverable_rules : Array(AlertGroupRecord)
      @storage.all_alert_groups.select do |rule|
        next false unless rule.enabled && rule.alert_type == "slack"
        url = rule.alert_target
        next false if url.blank?
        unless AlertRules.webhook_url?(url)
          Log.warn { "alert group #{rule.name.inspect}: #{url.inspect} is not a valid webhook URL (needs https://...); skipping" } if @warned.add?({rule.id, url})
          next false
        end
        true
      end
    end

    # Seconds between repeats; "once" never repeats.
    private def repeat_seconds(rule : AlertGroupRecord) : Int64
      rule.alert_count == "recurring" ? rule.alert_frequency_minutes.to_i64 * 60 : Int64::MAX
    end

    # Per {webhook, alert}, the most recent send by any rule using that webhook.
    private def latest_sent_states(rules : Array(AlertGroupRecord))
      url_of = rules.to_h { |r| {r.id, r.alert_target} }
      latest = {} of {String, {String, String}} => Storage::AlertStateRow
      @storage.all_alert_states.each do |row|
        url = url_of[row.rule_id]? || next
        key = {url, {row.hostname, row.check_name}}
        cur = latest[key]?
        latest[key] = row if cur.nil? || row.last_sent_at > cur.last_sent_at
      end
      latest
    end

    # Forget an alert only once it has stayed away for a while. Forgetting at
    # the first recovery would let a flapping check (e.g. CPU I/O wait hovering
    # at its limit) start a "new" alert every minute and ignore the rule's
    # frequency. A recurring rule keeps its memory for at least its own interval.
    private def prune_states(rules : Array(AlertGroupRecord), seen, now : Int64)
      by_id = rules.to_h { |r| {r.id, r} }
      @storage.all_alert_states.each do |row|
        rule = by_id[row.rule_id]? || next
        next if seen.has_key?({row.hostname, row.check_name})
        grace = {RECOVERY_GRACE, rule.alert_count == "recurring" ? rule.alert_frequency_minutes.to_i64 * 60 : 0_i64}.max
        @storage.clear_alert_state(row.rule_id, row.hostname, row.check_name) if now - row.last_active_at >= grace
      end
    end

    # Housekeeping for acknowledgements; returns the {host, check} pairs that
    # are currently muted.
    #  * A lapsed ack is dropped and the alert's sent-state wiped, so a check
    #    that is still failing notifies again as if new.
    #  * An ack whose check has stayed clear for RECOVERY_GRACE is dropped, so
    #    a later failure of the same check is not silently swallowed.
    private def reconcile_acks(agents : Hash(String, AgentRecord), now : Int64) : Set({String, String})
      muted = Set({String, String}).new
      @storage.all_acks.each do |ack|
        key = {ack.hostname, ack.check_name}
        if ack.expires_at <= now
          @storage.delete_ack(ack.hostname, ack.check_name)
          @storage.clear_alert_state_everywhere(ack.hostname, ack.check_name)
          next
        end
        agent = agents[ack.hostname]?
        if agent && failing_checks(agent, now).includes?(ack.check_name)
          @storage.touch_ack_active(ack.hostname, ack.check_name, now)
        elsif now - ack.last_active_at >= RECOVERY_GRACE
          @storage.delete_ack(ack.hostname, ack.check_name)
          next
        end
        muted << key
      end
      muted
    end

    # Names of the alerts a host currently has (the offline alert when stale).
    def failing_checks(agent : AgentRecord, now : Int64) : Array(String)
      return [Alert::OFFLINE] if agent.stale?(@stale_after, now)
      @storage.alert_checks_for(agent.id).map(&.name)
    end

    private def deliver(url : String, dues : Array(Due), now : Int64)
      last = @last_post[url]?
      return if last && now - last < MIN_GAP

      alerts = dues.map(&.alert).uniq { |a| {a.hostname, a.check} }
      @last_post[url] = now # counts failed attempts too: never faster than MIN_GAP
      if @poster.call(url, Slack.payload(alerts, @base_url))
        @first_due.delete(url)
        dues.each do |d|
          # One record per alert and webhook, held by the rule that sent it.
          (@rule_ids_by_url[url]? || [] of Int64).each { |id| @storage.clear_alert_state(id, d.alert.hostname, d.alert.check) }
          @storage.mark_alert_sent(d.rule_id, d.alert.hostname, d.alert.check, now)
        end
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
