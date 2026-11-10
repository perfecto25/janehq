module JaneHQ
  module Web
    # The values the alert group form posts, normalized. Kept as one struct so
    # the create and update routes share parsing, validation and — when
    # validation fails — re-rendering the form exactly as the user left it.
    struct AlertGroupForm
      getter name : String
      getter enabled : Bool
      getter targets : Array(AlertTarget)
      getter services : Array(String)
      getter statuses : Array(String)
      getter events : Array(String)
      getter alert_type : String
      getter alert_target : String
      getter alert_count : String
      getter alert_frequency_minutes : Int32

      def initialize(@name, @enabled, @targets, @services, @statuses, @events,
                     @alert_type, @alert_target, @alert_count, @alert_frequency_minutes)
      end

      # A blank form: watching nothing yet, with M/Monit's default statuses.
      def self.defaults : AlertGroupForm
        new(
          name: "",
          enabled: true,
          targets: [] of AlertTarget,
          services: [] of String,
          statuses: AlertRules::DEFAULT_STATUSES,
          events: [] of String,
          alert_type: AlertRules::DEFAULT_ALERT_TYPE,
          alert_target: "",
          alert_count: AlertRules::DEFAULT_ALERT_COUNT,
          alert_frequency_minutes: AlertRules::DEFAULT_ALERT_FREQUENCY_MINUTES,
        )
      end

      def self.from_record(record : AlertGroupRecord, targets : Array(AlertTarget)) : AlertGroupForm
        new(record.name, record.enabled, targets, record.services,
          record.statuses, record.events, record.alert_type, record.alert_target,
          record.alert_count, record.alert_frequency_minutes)
      end

      # The pickers are plain checkbox groups (so the form works without JS),
      # which means each arrives as a repeated body param.
      def self.from_params(env) : AlertGroupForm
        body = env.params.body
        new(
          (body["name"]? || "").strip,
          body["enabled"]? == "1",
          body.fetch_all("targets").compact_map { |t| AlertTarget.parse(t) }.uniq(&.token),
          body.fetch_all("services").map(&.strip).reject(&.blank?).uniq,
          AlertRules.known_statuses(body.fetch_all("statuses")),
          AlertRules.known_events(body.fetch_all("events")),
          (body["alert_type"]? || "").strip,
          (body["alert_target"]? || "").strip,
          (body["alert_count"]? || "").strip,
          (body["alert_frequency_minutes"]? || "").to_i? || AlertRules::DEFAULT_ALERT_FREQUENCY_MINUTES,
        )
      end

      def validate : String?
        return "Give the alert group a name." if @name.blank?
        return "Name is too long (60 characters max)." if @name.size > 60
        return "Pick at least one host or host group to watch." if @targets.empty?

        type = AlertRules.alert_type?(@alert_type)
        return "Choose an alert type." if type.nil?
        return "#{type.target_label} is required." if @alert_target.blank?
        if type.value == "email" && !@alert_target.includes?('@')
          return "#{@alert_target.inspect} does not look like an email address."
        end
        if type.value == "slack" && !AlertRules.webhook_url?(@alert_target)
          return "Slack webhook URL is not valid — it should look like https://hooks.slack.com/services/..."
        end
        return "Choose how many alerts to send." if AlertRules.alert_count?(@alert_count).nil?
        nil
      end

      # Selected-state lookups for the form's checkboxes.
      def target?(token : String) : Bool
        @targets.any? { |t| t.token == token }
      end

      def service?(name : String) : Bool
        @services.includes?(name)
      end

      # Each picker's collapsed label. Rendered server-side so the form still
      # reads correctly with JS disabled; public/alerts.js keeps them current.
      def target_summary : String
        @targets.map(&.display).join(", ").presence || "Select hosts"
      end

      def service_summary : String
        @services.join(", ").presence || "Any Service"
      end

      def status_summary : String
        AlertRules.status_labels(@statuses).join(", ").presence || "Any State"
      end

      def event_summary : String
        AlertRules.event_labels(@events).join(", ").presence || "Any Event"
      end

      def recurring? : Bool
        @alert_count == "recurring"
      end
    end

    # Alert group admin: list, create, edit, enable/disable, delete. An alert
    # group is one rule — hosts/host groups to watch, which check results
    # qualify (service, status, event), and how to deliver the alert. Delivery
    # itself is not built yet; rules are stored and displayed only.
    def self.define_alert_group_routes
      get "/alert-groups" do |env|
        alert_groups = storage.all_alert_groups
        targets = alert_groups.to_h { |g| {g.id, storage.alert_group_targets(g.id)} }
        render "src/web/views/alert_groups.ecr", "src/web/views/layout.ecr"
      end

      get "/alert-groups/new" do |env|
        group = nil
        form = AlertGroupForm.defaults
        error = nil
        host_groups = storage.all_groups
        hostnames = storage.all_agents.map(&.hostname).sort
        service_names = storage.distinct_check_names
        render "src/web/views/alert_group_form.ecr", "src/web/views/layout.ecr"
      end

      post "/alert-groups/create" do |env|
        form = AlertGroupForm.from_params(env)
        error = form.validate

        if error.nil?
          begin
            storage.create_alert_group(form.name, form.targets, form.services,
              form.statuses, form.events, form.alert_type, form.alert_target,
              form.alert_count, form.alert_frequency_minutes, form.enabled)
            env.redirect "/alert-groups"
          rescue
            error = "Could not save: an alert group named #{form.name.inspect} already exists."
          end
        end

        unless error.nil?
          group = nil
          host_groups = storage.all_groups
          hostnames = storage.all_agents.map(&.hostname).sort
          service_names = storage.distinct_check_names
          render "src/web/views/alert_group_form.ecr", "src/web/views/layout.ecr"
        end
      end

      get "/alert-groups/:id/edit" do |env|
        group = storage.alert_group_by_id(env.params.url["id"].to_i64)
        if group.nil?
          halt env, 404, "Unknown alert group"
        else
          form = AlertGroupForm.from_record(group, storage.alert_group_targets(group.id))
          error = nil
          host_groups = storage.all_groups
          hostnames = storage.all_agents.map(&.hostname).sort
          service_names = storage.distinct_check_names
          render "src/web/views/alert_group_form.ecr", "src/web/views/layout.ecr"
        end
      end

      post "/alert-groups/:id/update" do |env|
        group = storage.alert_group_by_id(env.params.url["id"].to_i64)
        if group.nil?
          halt env, 404, "Unknown alert group"
        else
          form = AlertGroupForm.from_params(env)
          error = form.validate

          if error.nil?
            begin
              storage.update_alert_group(group.id, form.name, form.targets,
                form.services, form.statuses, form.events, form.alert_type,
                form.alert_target, form.enabled, form.alert_count,
                form.alert_frequency_minutes)
              env.redirect "/alert-groups"
            rescue
              error = "Could not save: an alert group named #{form.name.inspect} already exists."
            end
          end

          unless error.nil?
            host_groups = storage.all_groups
            hostnames = storage.all_agents.map(&.hostname).sort
            service_names = storage.distinct_check_names
            render "src/web/views/alert_group_form.ecr", "src/web/views/layout.ecr"
          end
        end
      end

      post "/alert-groups/:id/toggle" do |env|
        group = storage.alert_group_by_id(env.params.url["id"].to_i64)
        storage.set_alert_group_enabled(group.id, !group.enabled) if group
        env.redirect "/alert-groups"
      end

      post "/alert-groups/:id/delete" do |env|
        storage.delete_alert_group(env.params.url["id"].to_i64)
        env.redirect "/alert-groups"
      end
    end
  end
end
