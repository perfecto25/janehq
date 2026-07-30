require "msgpack"
require "../models/payload"
require "../storage"

module JaneHQ
  # Decodes one raw agent message and persists it. The agent sends its report
  # as a JSON string that is then msgpack-encoded (see jane/src/daemon.cr), so
  # we msgpack-decode the bytes to a String and JSON-parse that.
  module Processor
    def self.decode(bytes : Bytes) : Payload
      json = String.from_msgpack(bytes)
      Payload.from_json(json)
    end

    def self.process(bytes : Bytes, storage : Storage) : Payload
      payload = decode(bytes)
      storage.persist(payload)
      payload
    end
  end
end
