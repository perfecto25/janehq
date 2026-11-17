require "base64"
require "http/client"
require "json"
require "uri"

module JaneHQ
  # Google OAuth 2.0 / OpenID Connect ("Sign in with Google").
  #
  # Authorization-code flow. The ID token is fetched server-to-server from
  # Google's token endpoint over TLS, so (per Google's docs) it needs no
  # signature check; we still verify audience, issuer, expiry, email_verified
  # and, if configured, the Workspace domain.
  module Google
    AUTH_URL  = "https://accounts.google.com/o/oauth2/v2/auth"
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    ISSUERS   = ["https://accounts.google.com", "accounts.google.com"]

    record Identity, sub : String, email : String

    class Error < Exception
    end

    private struct IdClaims
      include JSON::Serializable
      getter iss : String
      getter aud : String
      getter exp : Int64
      getter sub : String
      getter email : String?
      getter email_verified : Bool?
      getter hd : String?
    end

    private struct TokenResponse
      include JSON::Serializable
      getter id_token : String
    end

    def self.authorize_url(config : Config, redirect_uri : String, state : String) : String
      params = URI::Params.build do |p|
        p.add "client_id", config.google_client_id.not_nil!
        p.add "redirect_uri", redirect_uri
        p.add "response_type", "code"
        p.add "scope", "openid email"
        p.add "state", state
        p.add "prompt", "select_account"
        p.add "hd", config.google_domain.not_nil! # UX hint only; enforced in `identity`
      end
      "#{AUTH_URL}?#{params}"
    end

    # Exchanges the authorization code and returns the verified identity.
    # Raises Google::Error with a user-presentable message.
    def self.exchange(config : Config, redirect_uri : String, code : String) : Identity
      response = HTTP::Client.post(TOKEN_URL, form: {
        "code"          => code,
        "client_id"     => config.google_client_id.not_nil!,
        "client_secret" => config.google_client_secret.not_nil!,
        "redirect_uri"  => redirect_uri,
        "grant_type"    => "authorization_code",
      })
      raise Error.new("Google rejected the sign-in (#{response.status_code}).") unless response.success?
      id_token = TokenResponse.from_json(response.body).id_token
      identity(config, id_token)
    rescue ex : JSON::ParseException | JSON::SerializableError | IO::Error | Socket::Error
      raise Error.new("Could not complete Google sign-in.")
    end

    def self.identity(config : Config, id_token : String, now : Int64 = Time.utc.to_unix) : Identity
      payload = id_token.split('.')[1]? || raise Error.new("Malformed Google token.")
      claims = IdClaims.from_json(String.new(Base64.decode(payload.tr("-_", "+/"))))

      raise Error.new("Google token has the wrong issuer.") unless ISSUERS.includes?(claims.iss)
      raise Error.new("Google token is for a different application.") unless claims.aud == config.google_client_id
      raise Error.new("Google token has expired.") if claims.exp < now
      email = claims.email.try(&.strip.downcase)
      raise Error.new("Your Google account has no verified email address.") if email.nil? || email.empty? || claims.email_verified != true

      # Fail closed: with no domain configured nobody may sign in via Google.
      domain = config.google_domain || raise Error.new("Google sign-in is not configured.")
      unless claims.hd.try(&.downcase) == domain && email.ends_with?("@#{domain}")
        raise Error.new("Only #{domain} accounts may sign in with Google.")
      end
      Identity.new(claims.sub, email)
    rescue ex : JSON::ParseException | JSON::SerializableError | Base64::Error
      raise Error.new("Malformed Google token.")
    end

    # Finds the local account for a Google identity, creating it (read_only)
    # on first sign-in. Returns nil if the email's username is taken by a
    # non-Google account (can't happen with local usernames, which exclude '@',
    # but guards against manual DB edits).
    def self.find_or_create_user(storage : Storage, id : Identity) : UserRecord?
      if user = storage.user_by_google_sub(id.sub)
        return user
      end
      return nil if storage.user_by_name(id.email)
      storage.create_google_user(id.email, id.sub)
      storage.user_by_google_sub(id.sub)
    end
  end
end
