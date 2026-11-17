module JaneHQ
  module Web
    USER_NOTICES = {
      "created"  => "User created.",
      "updated"  => "User updated.",
      "deleted"  => "User deleted.",
      "disabled" => "User disabled — they can no longer sign in.",
      "enabled"  => "User enabled.",
    }

    def self.validate_username(name : String) : String?
      return "Usernames are 3-32 characters: letters, digits, dot, dash, underscore." unless USERNAME_RE.matches?(name)
      nil
    end

    # Users admin (superuser only — enforced by `guard`).
    def self.define_user_routes
      get "/users" do |env|
        users = storage.all_users
        me_id = env.get("uid").as(String).to_i64
        notice = USER_NOTICES[env.params.query["ok"]?]?
        error = env.params.query["err"]?.try { |e| USER_ERRORS[e]? }
        form_name = ""
        form_role = Role::READ_ONLY
        render "src/web/views/users.ecr", "src/web/views/layout.ecr"
      end

      post "/users/create" do |env|
        form_name = (env.params.body["username"]? || "").strip
        form_role = env.params.body["role"]? || ""
        password = env.params.body["password"]? || ""

        error = validate_username(form_name)
        error ||= "Choose a role." unless Role::ALL.includes?(form_role)
        error ||= Passwords.validate(password)
        error ||= "A user named #{form_name.inspect} already exists." if storage.user_by_name(form_name)

        if error.nil?
          storage.create_user(form_name, password, form_role)
          env.redirect "/users?ok=created"
        else
          users = storage.all_users
          me_id = env.get("uid").as(String).to_i64
          notice = nil
          form_role = Role::READ_ONLY unless Role::ALL.includes?(form_role)
          render "src/web/views/users.ecr", "src/web/views/layout.ecr"
        end
      end

      get "/users/:id/edit" do |env|
        user = storage.user_by_id(env.params.url["id"].to_i64)
        halt env, 404, "Unknown user" if user.nil?
        error = nil
        render "src/web/views/user_edit.ecr", "src/web/views/layout.ecr"
      end

      post "/users/:id/update" do |env|
        user = storage.user_by_id(env.params.url["id"].to_i64)
        halt env, 404, "Unknown user" if user.nil?
        role = env.params.body["role"]? || ""
        password = env.params.body["password"]? || ""

        error = "Choose a role." unless Role::ALL.includes?(role)
        if error.nil? && user.role == Role::SUPERUSER && role != Role::SUPERUSER && storage.superuser_count <= 1
          error = "There must be at least one superuser."
        end
        password = "" if user.google? # no local password for Google accounts
        error ||= Passwords.validate(password) unless password.empty?

        if error.nil?
          storage.set_user_role(user.id, role)
          storage.set_user_password(user.id, password) unless password.empty?
          env.redirect "/users?ok=updated"
        else
          render "src/web/views/user_edit.ecr", "src/web/views/layout.ecr"
        end
      end

      post "/users/:id/disable" do |env|
        user = storage.user_by_id(env.params.url["id"].to_i64)
        if user.nil?
          env.redirect "/users"
        elsif user.id.to_s == env.get("uid").as(String)
          env.redirect "/users?err=self_disable"
        elsif user.role == Role::SUPERUSER && !user.disabled && storage.active_superuser_count <= 1
          env.redirect "/users?err=last"
        else
          storage.set_user_disabled(user.id, true)
          env.redirect "/users?ok=disabled"
        end
      end

      post "/users/:id/enable" do |env|
        user = storage.user_by_id(env.params.url["id"].to_i64)
        storage.set_user_disabled(user.id, false) if user
        env.redirect "/users?ok=enabled"
      end

      post "/users/:id/delete" do |env|
        user = storage.user_by_id(env.params.url["id"].to_i64)
        if user.nil?
          env.redirect "/users"
        elsif user.id.to_s == env.get("uid").as(String)
          env.redirect "/users?err=self"
        elsif user.role == Role::SUPERUSER && storage.superuser_count <= 1
          env.redirect "/users?err=last"
        else
          storage.delete_user(user.id)
          env.redirect "/users?ok=deleted"
        end
      end
    end

    USER_ERRORS = {
      "self"         => "You can't delete your own account.",
      "self_disable" => "You can't disable your own account.",
      "last"         => "There must be at least one superuser.",
    }
  end
end
