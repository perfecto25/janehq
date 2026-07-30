module JaneHQ
  module Web
    def self.define_dashboard_routes
      # Dashboard shell. The agent list is loaded and refreshed by htmx from
      # /partials/agents.
      get "/" do |env|
        render "src/web/views/dashboard.ecr", "src/web/views/layout.ecr"
      end

      # htmx fragment: the agent table, most-alerting first.
      get "/partials/agents" do |env|
        agents = storage.all_agents
        stale_after = config.stale_after
        now = Time.utc.to_unix
        render "src/web/views/_agents.ecr"
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
