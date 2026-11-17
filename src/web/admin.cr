module JaneHQ
  module Web
    # Destinations for the Admin menu. "Hosts" is the dashboard at "/",
    # "Host Groups" lives in groups.cr, "Alerts" in alert_groups.cr and "Users"
    # in users.cr.
    def self.define_admin_routes
      # Where the Alerts menu item used to point.
      get "/alerts" do |env|
        env.redirect "/alert-groups"
      end
    end
  end
end
