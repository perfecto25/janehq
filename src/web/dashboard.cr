module JaneHQ
  module Web
    # The group the dashboard is filtered to: ?group=<id>, falling back to the
    # seeded "All Hosts" group (also used when the id is bogus or deleted).
    def self.selected_group(env) : GroupRecord
      id = env.params.query["group"]?.try &.to_i64?
      (id ? storage.group_by_id(id) : nil) || storage.default_group
    end

    def self.selected_group_from_body(env) : GroupRecord
      id = env.params.body["group"]?.try &.to_i64?
      (id ? storage.group_by_id(id) : nil) || storage.default_group
    end

    def self.define_dashboard_routes
      # Dashboard shell. The agent list is loaded and refreshed by htmx from
      # /partials/agents, scoped to the group in ?group=.
      get "/" do |env|
        groups = storage.all_groups
        user = env.session.string?("user") || ""
        # An explicit ?group= is remembered for this user; without one, use
        # their saved choice (so it survives sessions and re-logins).
        if env.params.query["group"]?
          group = selected_group(env)
          storage.set_pref(user, "dashboard_group", group.id.to_s) unless user.empty?
        else
          saved = user.empty? ? nil : storage.pref(user, "dashboard_group").try(&.to_i64?)
          group = (saved ? storage.group_by_id(saved) : nil) || storage.default_group
        end
        render "src/web/views/dashboard.ecr", "src/web/views/layout.ecr"
      end

      # htmx fragment: the agent table, most-alerting first.
      get "/partials/agents" do |env|
        group = selected_group(env)
        agents = storage.agents_in_group(group)
        stale_after = config.stale_after
        now = Time.utc.to_unix
        acks = storage.active_acks(now)
        render "src/web/views/_agents.ecr"
      end

      # Acknowledge a host's current alerts for `minutes` (clamped to 1 minute
      # .. 7 days): the notifier mutes them until then, and again notifies if
      # they are still failing. Alerts that start later are not covered.
      # Responds with the refreshed table so the click feels instant.
      post "/agents/:hostname/ack" do |env|
        hostname = env.params.url["hostname"]
        agent = storage.agent_by_hostname(hostname)
        halt env, 404, "Unknown agent" if agent.nil?
        now = Time.utc.to_unix
        minutes = (env.params.body["minutes"]?.try &.to_i? || 240).clamp(1, 7 * 24 * 60)
        names = if agent.stale?(config.stale_after, now)
                  [Alert::OFFLINE]
                else
                  storage.alert_checks_for(agent.id).map(&.name)
                end
        storage.ack_alerts(hostname, names, now + minutes.to_i64 * 60, now, env.session.string?("user") || "") unless names.empty?
        group = selected_group_from_body(env)
        agents = storage.agents_in_group(group)
        stale_after = config.stale_after
        acks = storage.active_acks(now)
        render "src/web/views/_agents.ecr"
      end

      post "/agents/:hostname/unack" do |env|
        storage.delete_host_acks(env.params.url["hostname"])
        group = selected_group_from_body(env)
        agents = storage.agents_in_group(group)
        stale_after = config.stale_after
        now = Time.utc.to_unix
        acks = storage.active_acks(now)
        render "src/web/views/_agents.ecr"
      end

      # htmx fragment: the "Glance" popover body — one host's alerting checks,
      # loaded on hover from the dashboard so you never leave the list.
      get "/partials/glance/:hostname" do |env|
        agent = storage.agent_by_hostname(env.params.url["hostname"])
        if agent.nil?
          halt env, 404, "Unknown agent"
        else
          alerts = storage.alert_checks_for(agent.id)
          stale_after = config.stale_after
          now = Time.utc.to_unix
          render "src/web/views/_glance.ecr"
        end
      end

      # Per-agent detail: all checks + full metrics.
      get "/agent/:hostname" do |env|
        agent = storage.agent_by_hostname(env.params.url["hostname"])
        if agent.nil?
          halt env, 404, "Unknown agent"
        else
          checks = storage.checks_for(agent.id)
          stale_after = config.stale_after
          now = Time.utc.to_unix
          partial = false
          render "src/web/views/agent.ecr", "src/web/views/layout.ecr"
        end
      end

      # Same content without the layout, for the live refresh below.
      get "/partials/agent/:hostname" do |env|
        agent = storage.agent_by_hostname(env.params.url["hostname"])
        if agent.nil?
          halt env, 404, "Unknown agent"
        else
          checks = storage.checks_for(agent.id)
          stale_after = config.stale_after
          now = Time.utc.to_unix
          partial = true
          render "src/web/views/agent.ecr"
        end
      end

      # Long-poll: returns as soon as the agent's last_seen differs from
      # ?since=, or after ~15s (so the page also notices a host going offline).
      get "/agent/:hostname/wait" do |env|
        host = env.params.url["hostname"]
        since = env.params.query["since"]?.try(&.to_i64?) || 0_i64
        seen = since
        30.times do
          a = storage.agent_by_hostname(host)
          halt env, 404, "Unknown agent" if a.nil?
          seen = a.last_seen
          break if seen != since
          sleep 0.5.seconds
        end
        env.response.content_type = "application/json"
        %({"last_seen":#{seen}})
      end
    end
  end
end
