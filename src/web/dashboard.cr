module JaneHQ
  module Web
    # The group the dashboard is filtered to: ?group=<id>, falling back to the
    # seeded "All Hosts" group (also used when the id is bogus or deleted).
    def self.selected_group(env) : GroupRecord
      id = env.params.query["group"]?.try &.to_i64?
      (id ? storage.group_by_id(id) : nil) || storage.default_group
    end

    def self.define_dashboard_routes
      # Dashboard shell. The agent list is loaded and refreshed by htmx from
      # /partials/agents, scoped to the group in ?group=.
      get "/" do |env|
        groups = storage.all_groups
        group = selected_group(env)
        render "src/web/views/dashboard.ecr", "src/web/views/layout.ecr"
      end

      # htmx fragment: the agent table, most-alerting first.
      get "/partials/agents" do |env|
        group = selected_group(env)
        agents = storage.agents_in_group(group)
        stale_after = config.stale_after
        now = Time.utc.to_unix
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
          render "src/web/views/agent.ecr", "src/web/views/layout.ecr"
        end
      end
    end
  end
end
