require "crypto/bcrypt/password"

module JaneHQ
  # Console roles, weakest first.
  module Role
    READ_ONLY = "read_only"
    STAFF     = "staff"
    SUPERUSER = "superuser"
    ALL       = [READ_ONLY, STAFF, SUPERUSER]

    def self.label(role : String) : String
      case role
      when READ_ONLY then "Read only"
      when STAFF     then "Staff"
      when SUPERUSER then "Superuser"
      else                role
      end
    end

    def self.describe(role : String) : String
      case role
      when READ_ONLY then "View everything except Users; change nothing."
      when STAFF     then "Create, edit and delete host groups, alert groups and acks; no Users."
      when SUPERUSER then "Full admin rights, including Users."
      else                ""
      end
    end

    # staff and above may change host groups / alert groups / acks.
    def self.can_write?(role : String?) : Bool
      role == STAFF || role == SUPERUSER
    end
  end

  # UI themes (value, name, blurb); the first is the default.
  THEMES = [
    {"batman", "Bruce Wayne", "night"},
    {"fluffy", "Dolly", "light & creamy"},
    {"kramer", "Tony Montana", "neon glow"},
    {"sherlock", "Sherlock", "cool gray"},
  ]
  DEFAULT_THEME = "batman"

  def self.theme?(name : String?) : String?
    name if name && THEMES.any? { |t| t[0] == name }
  end

  USERNAME_RE = /\A[A-Za-z0-9._-]{3,32}\z/

  # Initial superuser created on first start when no users exist.
  DEFAULT_SUPERUSER = "superjane"

  module Passwords
    MIN_LENGTH = 12 # passwords chosen by users
    MAX_LENGTH = 72 # bcrypt only uses the first 72 bytes

    # Unambiguous characters (no 0/O, 1/l/I) plus a few symbols.
    ALPHABET = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!#%+-=@^_"

    # Random password of 15..40 characters (inclusive) from a CSPRNG.
    def self.generate : String
      length = Random::Secure.rand(15..40)
      String.build(length) { |s| length.times { s << ALPHABET[Random::Secure.rand(ALPHABET.size)] } }
    end

    def self.hash(password : String) : String
      Crypto::Bcrypt::Password.create(password).to_s
    end

    def self.verify?(password : String, hash : String) : Bool
      Crypto::Bcrypt::Password.new(hash).verify(password)
    rescue
      false
    end

    # Stored for Google-only accounts; `verify?` rescues the parse error -> false.
    NO_PASSWORD = "!google"

    # Used for unknown usernames so login timing doesn't reveal which exist.
    DUMMY_HASH = hash("not-a-real-password")

    def self.validate(password : String) : String?
      return "Password must be at least #{MIN_LENGTH} characters." if password.size < MIN_LENGTH
      return "Password must be at most #{MAX_LENGTH} characters." if password.bytesize > MAX_LENGTH
      nil
    end
  end
end
