require "json"

module JaneHQ
  module Web
    # Host group admin: list, create, edit membership, delete. The dual-column
    # drag-and-drop form posts its "in group" column as a JSON array of
    # hostnames in the `hostnames` field (see public/groups.js).
    def self.define_group_routes
      get "/host-groups" do |env|
        groups = storage.all_groups
        agent_count = storage.all_agents.size
        render "src/web/views/host_groups.ecr", "src/web/views/layout.ecr"
      end

      get "/host-groups/new" do |env|
        group = nil
        name = ""
        selected = [] of String
        available = storage.all_agents.map(&.hostname).sort
        error = nil
        render "src/web/views/group_form.ecr", "src/web/views/layout.ecr"
      end

      post "/host-groups/create" do |env|
        name = (env.params.body["name"]? || "").strip
        selected = parse_hostnames(env.params.body["hostnames"]?)
        error = validate_group_name(name)

        if error.nil?
          begin
            storage.create_group(name, selected)
            env.redirect "/host-groups"
          rescue ex
            error = "Could not save: a group named #{name.inspect} already exists."
          end
        end

        unless error.nil?
          group = nil
          available = storage.all_agents.map(&.hostname).sort - selected
          render "src/web/views/group_form.ecr", "src/web/views/layout.ecr"
        end
      end

      get "/host-groups/:id/edit" do |env|
        group = storage.group_by_id(env.params.url["id"].to_i64)
        if group.nil? || group.default
          halt env, 404, "Unknown host group"
        else
          name = group.name
          selected = storage.group_hostnames(group.id)
          available = storage.all_agents.map(&.hostname).sort - selected
          error = nil
          render "src/web/views/group_form.ecr", "src/web/views/layout.ecr"
        end
      end

      post "/host-groups/:id/update" do |env|
        group = storage.group_by_id(env.params.url["id"].to_i64)
        if group.nil? || group.default
          halt env, 404, "Unknown host group"
        else
          name = (env.params.body["name"]? || "").strip
          selected = parse_hostnames(env.params.body["hostnames"]?)
          error = validate_group_name(name)

          if error.nil?
            begin
              storage.update_group(group.id, name, selected)
              env.redirect "/host-groups"
            rescue ex
              error = "Could not save: a group named #{name.inspect} already exists."
            end
          end

          unless error.nil?
            available = storage.all_agents.map(&.hostname).sort - selected
            render "src/web/views/group_form.ecr", "src/web/views/layout.ecr"
          end
        end
      end

      post "/host-groups/:id/delete" do |env|
        group = storage.group_by_id(env.params.url["id"].to_i64)
        storage.delete_group(group.id) if group && !group.default
        env.redirect "/host-groups"
      end
    end

    def self.validate_group_name(name : String) : String?
      return "Give the group a name." if name.blank?
      return "Name is too long (60 characters max)." if name.size > 60
      return "#{Storage::DEFAULT_GROUP_NAME.inspect} is reserved." if name == Storage::DEFAULT_GROUP_NAME
      nil
    end

    # The form posts the "Hosts in Group" column as a JSON array.
    def self.parse_hostnames(raw : String?) : Array(String)
      return [] of String if raw.nil? || raw.blank?
      Array(String).from_json(raw)
    rescue
      [] of String
    end
  end
end
