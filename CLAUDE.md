# JaneHQ

Admin console + alerting server for the **Jane** monitoring agent — conceptually
M/Monit to Jane's Monit. Jane agents run on many hosts and push check results +
system metrics to JaneHQ; JaneHQ stores the latest state per host and shows it on a
web dashboard ordered by alert severity.

- Companion agent lives at `~/dev/crystal/jane` (also Crystal).
- Language: Crystal (`>= 1.19.1`). Web: Kemal. Storage: SQLite. Frontend: htmx.

## Running

```bash
mkdir -p bin
crystal build src/server.cr -o bin/janehq
JANEHQ_ADMIN_PASSWORD=secret JANEHQ_PORT=8080 ./bin/janehq
```

Two listeners in one process:
- **Web console** on `JANEHQ_PORT` (default `80`) — login + dashboard.
- **Ingest** on `JANEHQ_INGEST_PORT` (default `25900`) — msgpack reports from agents.

> Port 80 needs privilege: `sudo setcap 'cap_net_bind_service=+ep' ./bin/janehq`, or set
> `JANEHQ_PORT=8080` for local dev.

### Env config (`src/config.cr`)
`JANEHQ_ADMIN_PASSWORD` (**required**), `JANEHQ_ADMIN_USER` (default `admin`),
`JANEHQ_PORT` (80), `JANEHQ_INGEST_PORT` (25900), `JANEHQ_DB_PATH` (`./janehq.db`),
`JANEHQ_SESSION_SECRET` (random if unset), `JANEHQ_STALE_AFTER` (30s).

### Point a Jane agent here
In the agent's `config.toml`:
```toml
[hq]
enabled = true
host = "<janehq-host>"
port = 25900
```

## Tests / checks
```bash
crystal spec                 # 9 examples (wire decode, persist, ordering, staleness, host groups)
crystal tool format --check
```

## Architecture

The library (`src/janehq.cr`) is kept require-safe (defines `JaneHQ.run` but does not
call it) so specs can require it without starting servers. The executable is
`src/server.cr` (the shard target `janehq`), which just calls `JaneHQ.run`.

```
src/janehq.cr              library + JaneHQ.run (config -> DB -> spawn ingest -> Kemal)
src/server.cr              executable entrypoint (target main)
src/config.cr              Config.from_env
src/models/payload.cr      Payload / Check / Metrics — mirrors the agent's structs
src/storage.cr             Storage (SQLite/WAL): migrations, persist, queries + row structs
src/ingest/tcp_server.cr   IngestServer — raw TCP :25900, fiber per connection
src/ingest/processor.cr    Processor.decode/process — bytes -> Payload -> persist
src/web/server.cr          Web.configure: session, auth guard, wires routes
src/web/auth.cr            GET/POST /login, POST /logout (constant-time cred compare)
src/web/dashboard.cr       GET / , GET /partials/agents + /partials/glance/:hostname, GET /agent/:hostname
src/web/groups.cr          host group CRUD (list, new, create, edit, update, delete)
src/web/admin.cr           placeholder pages for the unbuilt Admin menu items (/users, /alerts)
src/web/views/*.ecr        layout, layout_bare, login, dashboard, _agents, _glance, agent,
                           host_groups, group_form, placeholder
public/{app.css,htmx.min.js,glance.js,nav.js,groups.js}
```

Asset URLs carry `?v=JaneHQ::ASSET_VERSION` (server start time) — Kemal's StaticFileHandler
sends no `Cache-Control`, so without it browsers serve a stale `app.css` after a rebuild.

### Wire format (critical — matches the agent exactly)
The agent (`jane/src/daemon.cr`) builds `{checks, metrics, unmonitored, config}`, calls
`results.to_json` to get a **JSON string**, then `.to_msgpack` on that string, and writes
the bytes over a raw TCP socket that it **closes** after one message. **No length prefix.**
So the receiver: read to EOF → `String.from_msgpack(bytes)` → `Payload.from_json(str)`
(see `Processor.decode`). `hostname` (in `metrics`) is the only agent identifier — there is
no auth/handshake. Agents heartbeat every ~10s sending all checks + metrics.

### Storage model
Latest-state only (no history yet). `agents` table is upserted per report on `hostname`
(`ON CONFLICT`), with a denormalized `alert_count` for sorting; `checks` are deleted +
reinserted each report (current snapshot). Dashboard query:
`ORDER BY alert_count DESC, last_seen DESC`. An agent is "stale/offline" when
`now - last_seen > JANEHQ_STALE_AFTER`.

`host_groups` + `host_group_members` hold user-defined groups. Membership is keyed by
**hostname** (the agent's only wire identifier), so a host can be grouped before it ever
reports. The seeded `All Hosts` group has `is_default = 1`, **no** membership rows — it
means "everything" — and the storage layer's update/delete are no-ops against it.

### Web notes
- Kemal serves `./public` via StaticFileHandler, which runs *before* the `before_all` auth
  guard, so assets bypass auth and only `/login` needs whitelisting.
- Dashboard shell has an htmx div `hx-get="/partials/agents?group=<id>" hx-trigger="load, every 3s"`;
  the server returns the `_agents.ecr` HTML fragment and htmx swaps it in. `?group=` selects
  the host group to show (bad/missing id falls back to `All Hosts`).
- The Glance modal (`#glance` in `dashboard.ecr`) sits *outside* that swapped div so the 3s
  refresh can't tear it down; `glance.js` also cancels the poll while it's open.
- The New/Edit Group form posts its "Hosts in Group" column as a JSON array in the
  `hostnames` field (`groups.js` serializes it on submit).
- ECR paths in `render` are resolved relative to the CWD at compile time — build/run from
  the project root.

## Roadmap
- **Phase 1 (done):** dashboard + console, servers ordered by severity, msgpack ingest.
- **Phase 2:** agent groups (Prod/UAT) **done** — create/edit/delete groups, dashboard
  filters by group. Still open: outbound alerting, alert level/frequency control,
  multi-user accounts (needs schema/auth expansion).
- **Phase 3:** historical time-series metrics dashboards (CPU/RAM/filesystem). The agent
  already sends these metrics; we currently store only the latest — add history tables.

## Status / gotchas
- Nothing has been committed yet; the repo tree (`src/`, `spec/`, `shard.yml`, etc.) is
  untracked. Branch off `main` before committing.
- `spec/janehq_spec.cr` replaced the generated intentionally-failing placeholder with real
  tests; `spec/spec_helper.cr` requires only the pieces under test (not Kemal).
