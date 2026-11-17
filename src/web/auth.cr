module JaneHQ
  module Web
    # Role of the signed-in user for this request (set by the access guard).
    def self.role(env) : String?
      env.get?("role").try(&.as?(String))
    end

    def self.theme(env) : String
      env.get?("theme").try(&.as?(String)) || DEFAULT_THEME
    end

    def self.can_write?(env) : Bool
      Role.can_write?(role(env))
    end

    def self.superuser?(env) : Bool
      role(env) == Role::SUPERUSER
    end

    # Minimum role needed for a request, nil = any signed-in user.
    # Users section: superusers only. Anything that changes state, and the
    # create/edit forms, need staff. Everyone may sign out and manage their own
    # password.
    def self.required_role(method : String, path : String) : String?
      return Role::SUPERUSER if path == "/users" || path.starts_with?("/users/")
      return nil if path == "/logout" || path == "/account" || path.starts_with?("/account/")
      return Role::STAFF unless method == "GET" || method == "HEAD"
      return Role::STAFF if path.ends_with?("/new") || path.ends_with?("/edit")
      nil
    end

    # Session -> live user lookup on every request, so role changes and
    # deletions take effect immediately. Returns nil to let the request
    # through, else {status, body} for the before_all block to halt with
    # (`halt` is a macro that needs the route block, so it can't live here).
    def self.guard(env) : {Int32, String}?
      path = env.request.path
      return nil if path == "/login" || path == "/auth/google" || path == "/auth/google/callback"

      user = env.session.string?("user").try { |n| storage.user_by_name(n) }
      if user.nil?
        env.session.destroy
        env.response.headers["Location"] = "/login"
        return {302, ""}
      end

      if user.disabled
        env.session.destroy
        env.response.headers["Location"] = "/login"
        return {302, ""}
      end

      env.set "role", user.role
      env.set "uid", user.id.to_s
      env.set "theme", JaneHQ.theme?(storage.pref(user.username, "theme")) || JaneHQ::DEFAULT_THEME
      need = required_role(env.request.method, path)
      if (need == Role::SUPERUSER && user.role != Role::SUPERUSER) ||
         (need == Role::STAFF && !Role.can_write?(user.role))
        return {403, "Forbidden — your role (#{Role.label(user.role)}) cannot do this."}
      end
      nil
    end

    # Where Google sends the browser back to. JANEHQ_BASE_URL when set (must
    # match the redirect URI registered in Google Cloud), else derived from the
    # request.
    def self.google_redirect_uri(env) : String
      base = config.base_url
      unless base
        scheme = env.request.headers["X-Forwarded-Proto"]? == "https" ? "https" : "http"
        base = "#{scheme}://#{env.request.headers["Host"]? || "localhost"}"
      end
      "#{base}/auth/google/callback"
    end

    GOOGLE_ERRORS = {
      "google_off" => "Google sign-in is not configured.",
    }

    def self.define_auth_routes
      get "/login" do |env|
        error = env.params.query["err"]?.try { |e| GOOGLE_ERRORS[e]? } || env.session.string?("login_error")
        env.session.delete_string("login_error")
        google = config.google_enabled?
        temp_users = storage.temp_password_users
        render "src/web/views/login.ecr", "src/web/views/layout_bare.ecr"
      end

      get "/auth/google" do |env|
        unless config.google_enabled?
          next env.redirect "/login?err=google_off"
        end
        state = Random::Secure.hex(24)
        env.session.string("oauth_state", state)
        env.redirect Google.authorize_url(config, google_redirect_uri(env), state)
      end

      get "/auth/google/callback" do |env|
        fail = ->(msg : String) {
          env.session.string("login_error", msg)
          env.redirect "/login"
        }
        next fail.call("Google sign-in is not configured.") unless config.google_enabled?

        expected = env.session.string?("oauth_state")
        env.session.delete_string("oauth_state")
        given = env.params.query["state"]?
        if expected.nil? || given.nil? || !Crypto::Subtle.constant_time_compare(expected, given)
          next fail.call("Google sign-in failed (invalid state). Please try again.")
        end
        if env.params.query["error"]?
          next fail.call("Google sign-in was cancelled.")
        end
        code = env.params.query["code"]?
        next fail.call("Google sign-in failed (no code).") if code.nil? || code.empty?

        begin
          identity = Google.exchange(config, google_redirect_uri(env), code)
          user = Google.find_or_create_user(storage, identity)
          next fail.call("An account named #{identity.email} already exists.") if user.nil?
          next fail.call("This account has been disabled.") if user.disabled
          env.session.string("user", user.username)
          env.redirect "/"
        rescue ex : Google::Error
          fail.call(ex.message || "Google sign-in failed.")
        end
      end

      post "/login" do |env|
        username = (env.params.body["username"]? || "").strip
        password = env.params.body["password"]? || ""

        user = storage.user_by_name(username)
        # Always run a bcrypt verify so unknown usernames cost the same time.
        ok = Passwords.verify?(password, user ? user.password_hash : Passwords::DUMMY_HASH)

        if user && ok && !user.google? && !user.disabled
          env.session.string("user", user.username)
          env.redirect "/"
        else
          error = user && ok && user.disabled ? "This account has been disabled." : "Invalid username or password."
          google = config.google_enabled?
          temp_users = storage.temp_password_users
          render "src/web/views/login.ecr", "src/web/views/layout_bare.ecr"
        end
      end

      post "/logout" do |env|
        env.session.destroy
        env.redirect "/login"
      end

      # Own account: change your password (any role).
      get "/account" do |env|
        error = nil
        me = storage.user_by_id(env.get("uid").as(String).to_i64).not_nil!
        ok = env.params.query["ok"]?
        render "src/web/views/account.ecr", "src/web/views/layout.ecr"
      end

      # Remember the user's theme (per login, so it follows them across devices).
      post "/account/theme" do |env|
        if name = JaneHQ.theme?(env.params.body["theme"]?)
          storage.set_pref(env.session.string("user"), "theme", name)
        end
        back = env.params.body["back"]? || "/"
        env.redirect(back.starts_with?("/") && !back.starts_with?("//") ? back : "/")
      end

      post "/account/password" do |env|
        me = storage.user_by_id(env.get("uid").as(String).to_i64).not_nil!
        halt env, 400, "Google accounts have no local password." if me.google?
        current = env.params.body["current"]? || ""
        new_pw = env.params.body["password"]? || ""
        confirm = env.params.body["confirm"]? || ""

        error = if !Passwords.verify?(current, me.password_hash)
                  "Current password is incorrect."
                elsif new_pw != confirm
                  "The new passwords don't match."
                else
                  Passwords.validate(new_pw)
                end

        if error.nil?
          storage.set_user_password(me.id, new_pw)
          env.redirect "/account?ok=1"
        else
          ok = nil
          render "src/web/views/account.ecr", "src/web/views/layout.ecr"
        end
      end
    end
  end
end
