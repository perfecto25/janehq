module JaneHQ
  module Web
    # Destinations for the Admin menu. "Hosts" is the dashboard at "/",
    # "Host Groups" lives in groups.cr and "Alerts" in alert_groups.cr; Users
    # is still a Phase 2 feature and renders a placeholder so the menu never
    # dead-ends.
    def self.define_admin_routes
      get "/users" do |env|
        title = "Users"
        note = "Multi-user accounts are a Phase 2 feature — not built yet. The console currently has the single admin login from JANEHQ_ADMIN_USER."
        render "src/web/views/placeholder.ecr", "src/web/views/layout.ecr"
      end

      # Where the Alerts menu item used to point.
      get "/alerts" do |env|
        env.redirect "/alert-groups"
      end
    end
  end
end
