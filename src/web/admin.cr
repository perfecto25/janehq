module JaneHQ
  module Web
    # Destinations for the Admin menu. "Hosts" is the dashboard at "/" and
    # "Host Groups" lives in groups.cr; the rest are Phase 2 features
    # (multi-user accounts, outbound alerting) and render a placeholder so the
    # menu never dead-ends.
    def self.define_admin_routes
      get "/users" do |env|
        title = "Users"
        note = "Multi-user accounts are a Phase 2 feature — not built yet. The console currently has the single admin login from JANEHQ_ADMIN_USER."
        render "src/web/views/placeholder.ecr", "src/web/views/layout.ecr"
      end

      get "/alerts" do |env|
        title = "Alerts"
        note = "Outbound alerting with level and frequency control is a Phase 2 feature — not built yet. Alerting checks are shown per host on the dashboard."
        render "src/web/views/placeholder.ecr", "src/web/views/layout.ecr"
      end
    end
  end
end
