require "./janehq"

# Executable entrypoint. Kept separate from the library (src/janehq.cr) so that
# requiring the library in specs does not start the servers.
JaneHQ.run
