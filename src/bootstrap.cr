require "log"
require "./config"
require "./storage"
require "./models/user"

module JaneHQ
  # RESET_SUPERUSER=true: (re)create `superjane` with a fresh generated password,
  # printed to stdout only. Also re-enables the account and restores the
  # superuser role. A same-named Google account is left alone.
  def self.reset_superuser(storage : Storage) : Bool
    pw = Passwords.generate
    if user = storage.user_by_name(DEFAULT_SUPERUSER)
      if user.google?
        Log.for("janehq").warn { "RESET_SUPERUSER ignored: #{DEFAULT_SUPERUSER.inspect} is a Google account" }
        return false
      end
      storage.set_user_role(user.id, Role::SUPERUSER)
      storage.set_user_password(user.id, pw, temp: true)
      storage.set_user_disabled(user.id, false)
    else
      storage.create_user(DEFAULT_SUPERUSER, pw, Role::SUPERUSER, temp: true)
    end
    print_superuser_password("RESET_SUPERUSER was set: the #{DEFAULT_SUPERUSER} password was reset.", pw)
    true
  end

  private def self.print_superuser_password(headline : String, pw : String)
    STDOUT.puts <<-MSG

      ============================================================
       JaneHQ: #{headline}
         username: #{DEFAULT_SUPERUSER}
         password: #{pw}
       This temporary password is shown only here. Sign in and change it.
       Remove RESET_SUPERUSER from the environment, or it resets on every start.
      ============================================================

      MSG
    STDOUT.flush
  end

  # On first start (no users),: create the initial superuser. With
  # JANEHQ_ADMIN_PASSWORD set, that is JANEHQ_ADMIN_USER with that password
  # (keeps existing deployments working); otherwise `superjane` with a
  # generated 15-40 character password written to stdout only — the login
  # page just says where to look.
  def self.bootstrap_users(config : Config, storage : Storage)
    return if config.reset_superuser && reset_superuser(storage)
    return if storage.user_count > 0

    if (pw = config.admin_password)
      storage.create_user(config.admin_user, pw, Role::SUPERUSER)
      Log.for("janehq").info { "created superuser #{config.admin_user.inspect} from JANEHQ_ADMIN_PASSWORD" }
    else
      pw = Passwords.generate
      storage.create_user(DEFAULT_SUPERUSER, pw, Role::SUPERUSER, temp: true)
      print_superuser_password("no users existed, so an initial superuser was created.", pw)
    end
  end
end
