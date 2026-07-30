require "crypto/subtle"

module JaneHQ
  module Web
    def self.define_auth_routes
      get "/login" do |env|
        error = nil
        render "src/web/views/login.ecr", "src/web/views/layout_bare.ecr"
      end

      post "/login" do |env|
        cfg = config
        username = env.params.body["username"]? || ""
        password = env.params.body["password"]? || ""

        user_ok = Crypto::Subtle.constant_time_compare(username, cfg.admin_user)
        pass_ok = Crypto::Subtle.constant_time_compare(password, cfg.admin_password)

        if user_ok && pass_ok
          env.session.string("user", username)
          env.redirect "/"
        else
          error = "Invalid username or password."
          render "src/web/views/login.ecr", "src/web/views/layout_bare.ecr"
        end
      end

      post "/logout" do |env|
        env.session.destroy
        env.redirect "/login"
      end
    end
  end
end
