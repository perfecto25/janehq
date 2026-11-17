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
JANEHQ_UI_PORT=8080 ./bin/janehq   # first start prints a generated `superjane` password to stdout
```

Two listeners in one process:
- **Web console** on `JANEHQ_UI_PORT` (default `80`) — login + dashboard.
- **Ingest** on `JANEHQ_INGEST_PORT` (default `25900`) — msgpack reports from agents.

> Port 80 needs privilege: `sudo setcap 'cap_net_bind_service=+ep' ./bin/janehq`, or set
> `JANEHQ_UI_PORT=8080` for local dev.

### Env config (`src/config.cr`)
`JANEHQ_ADMIN_PASSWORD` + `JANEHQ_ADMIN_USER` (default `admin`) — both optional, only used to seed the first superuser when the `users` table is empty,
`RESET_SUPERUSER` (`true`; also `JANEHQ_RESET_SUPERUSER`) — lost-password recovery: on startup, `superjane` is created or reset (superuser role, enabled, new generated temp password printed to stdout). Unset it afterwards or it resets on every start,
`JANEHQ_UI_PORT` (80), `JANEHQ_INGEST_PORT` (25900), `JANEHQ_DEBUG_LEVEL` (`info` default | `debug`: also logs every web request with params — secrets redacted — and each ingested report as pretty JSON; replaces `LOG_LEVEL`), `JANEHQ_DB_PATH` (`./janehq.db`),
`JANEHQ_SESSION_SECRET` (random if unset), `JANEHQ_STALE_AFTER` (30s), `JANEHQ_METRICS_RETENTION` (days of metric history kept, default 360; older `metrics_1m`/`metrics_1h` rows are deleted by the 5-minute rollup loop), `JANEHQ_BASE_URL` (optional; public console URL, enables host links in Slack alerts and is the base of the Google OAuth redirect URI),
`JANEHQ_GOOGLE_CLIENT_ID` + `JANEHQ_GOOGLE_CLIENT_SECRET` + `JANEHQ_GOOGLE_DOMAIN` (all three required to enable "Sign in with Google"; empty/unset domain = Google sign-in off, with a startup warning).

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
crystal spec                 # 17 examples (wire decode, persist, ordering, staleness,
                             # host groups, alert groups, check-name -> event mapping)
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
src/models/alert_rules.cr  AlertTarget + AlertRules: the Service/State/Event/Alert-Type
                           vocabularies an alert group is built from
src/storage.cr             Storage (SQLite/WAL): migrations, persist, queries + row structs
src/ingest/tcp_server.cr   IngestServer — raw TCP :25900, fiber per connection
src/ingest/processor.cr    Processor.decode/process — bytes -> Payload -> persist
src/web/server.cr          Web.configure: session, auth guard, wires routes
src/web/auth.cr            GET/POST /login, POST /logout (constant-time cred compare)
src/web/dashboard.cr       GET / , GET /partials/agents + /partials/glance/:hostname, GET /agent/:hostname
src/web/groups.cr          host group CRUD (list, new, create, edit, update, delete)
src/web/alert_groups.cr    alert group CRUD + AlertGroupForm (parse/validate the rule form)
src/web/admin.cr           /alerts -> /alert-groups
src/web/users.cr           Users admin (superuser only) + src/web/auth.cr has login, /account, role guard
src/models/user.cr         Role constants, Passwords (bcrypt, generator 15-40 chars)
src/web/views/*.ecr        layout, layout_bare, login, dashboard, _agents, _glance, agent,
                           host_groups, group_form, alert_groups, alert_group_form, placeholder
public/{app.css,htmx.min.js,glance.js,nav.js,groups.js,alerts.js,logo.svg}
```

Asset URLs carry `?v=JaneHQ::ASSET_VERSION` (server start time) — Kemal's StaticFileHandler
sends no `Cache-Control`, so without it browsers serve a stale `app.css` after a rebuild.

`public/logo.svg` is the topbar brand — the JaneHQ lockup (bow mark + "Jane" + a red
"HQ"), ~2.86:1 wide. It is **inlined**, not linked: `JaneHQ::LOGO_SVG` reads it at
compile time (`read_file`, XML prolog stripped since that is invalid inside HTML) and
`layout.ecr` emits it. Inlining is what lets the bow and "Jane" paths use
`fill:currentColor` and follow `.brand`'s colour on the dark topbar while "HQ" keeps its
`#ff2a2a`. Consequences: **editing logo.svg needs a rebuild** (`?v=ASSET_VERSION` cache
busting does not apply to it), and size is set by `.brand svg { width }` in `app.css`.

### Users & roles
`users` table (bcrypt hashes, `temp_password` flag). On start with **no users**, `JaneHQ.bootstrap_users`
creates `superjane` with a generated 15-40 char password printed **to stdout only**; the login
page just says where to look (while any `temp_password` account exists). If
`JANEHQ_ADMIN_PASSWORD` is set it seeds that user instead. Roles: `read_only` (view all except
Users), `staff` (+ create/edit/delete host groups, alert groups, acks), `superuser` (+ Users).
Enforced by `Web.guard` (before_all, live DB lookup per request; `required_role` maps
method/path -> role: any non-GET and any `/new`|`/edit` need staff, `/users*` superuser;
`/account` + `/logout` open to all). Views hide write controls via `Web.can_write?(env)`.
Last superuser can't be deleted/demoted; you can't delete yourself. Lost password: start with
`RESET_SUPERUSER=true` (see `docs/reset-superuser.md`).

### Google sign-in
Setup guide for operators: `docs/google-oauth.md` (docs live in the repo only, not in the UI).
Optional, alongside local passwords. Create an OAuth 2.0 *Web* client in Google Cloud and register
`<JANEHQ_BASE_URL>/auth/google/callback` as the redirect URI. `src/web/google.cr` runs the
authorization-code flow (`GET /auth/google` -> Google -> `GET /auth/google/callback`, CSRF `state` kept in
the session), verifies aud/iss/exp/`email_verified` and the `hd` claim + email domain
(`Config#google_enabled?` requires `JANEHQ_GOOGLE_DOMAIN`; `Google.identity` also fails closed without it). First sign-in creates a `read_only` user (username = email, `users.google_sub` = Google's
stable id; the stored hash `Passwords::NO_PASSWORD` can never verify). Superusers promote them on `/users`.
Google users have no password form; deleting one just re-creates them as `read_only` on next sign-in.

### Wire format (critical — matches the agent exactly)
The agent (`jane/src/daemon.cr`) builds `{checks, metrics, unmonitored, config}`, calls
`results.to_json` to get a **JSON string**, then `.to_msgpack` on that string, and writes
the bytes over a raw TCP socket that it **closes** after one message. **No length prefix.**
So the receiver: read to EOF → `String.from_msgpack(bytes)` → `Payload.from_json(str)`
(see `Processor.decode`). `hostname` (in `metrics`) is the only agent identifier — there is
no auth/handshake. Agents heartbeat every ~10s sending all checks + metrics.

### Storage model
Newer agents also send `metrics.top_procs` (`by_memory` / `by_cpu` / `by_disk_io`, each a list of
`{pid,name,cpu_pct,rss_bytes,io_read_bps?,io_write_bps?}`); the latest snapshot per host is kept as JSON in
`agent_procs` and shown on the Metrics page ("Top processes"). History: `agent_procs_history` keeps one snapshot per 5 min (first of the bucket), thinned to one per hour after 7 days, deleted past `JANEHQ_METRICS_RETENTION`; the Metrics page's "Processes at (UTC)" time (default: live for today, else end of the chosen day) picks the snapshot via `Storage#top_procs_at`. Older agents simply omit it.

Latest-state only (no history yet). `agents` table is upserted per report on `hostname`
(`ON CONFLICT`), with a denormalized `alert_count` for sorting; `checks` are deleted +
reinserted each report (current snapshot). Dashboard query:
`ORDER BY alert_count DESC, last_seen DESC`. An agent is "stale/offline" when
`now - last_seen > JANEHQ_STALE_AFTER`.

`alert_groups` + `alert_group_targets` hold alerting rules. One row per rule: the
condition lists (`services`, `statuses`, `events`) are **JSON arrays** — small, always
read whole, and matched in Crystal against an incoming report — where an **empty list
means "any"**. `alert_group_targets` is what the rule watches: `kind` is `host`
(`ref` = hostname) or `group` (`ref` = `host_groups.id` as text), both in one table
because the form picks from a single list; forms post them as `host:web-01` /
`group:3` tokens (`AlertTarget.parse`). The Service choices are the distinct
`checks.name` values agents have reported; `AlertRules.event_for` maps such a name
("Process nginx") to its event family ("process"). **Delivery: only Slack is implemented**
(`src/alerts/notifier.cr` fiber, ticks every 10s; `exec`/`email` are stored only). Slack
alerts (failing checks + offline hosts) are pooled into one Block Kit message per webhook
URL (`alert_target`), posted at most once per 60s per URL; `alert_state` table tracks what
a rule already sent (once = once per failure episode, recurring = every
`alert_frequency_minutes`), pruned on recovery. Failed posts retry after the 60s gap.

**Acknowledgements** (`alert_acks`, dashboard "Ack" column): clicking 1h/4h/1d/7d on an
alerting row acks that host's *currently failing* checks (or `Host offline`) — one row per
{host, check}, always with an expiry. The notifier (`reconcile_acks`) mutes acked alerts for
every rule; when an ack lapses it drops it and wipes `alert_state` so a still-failing check
notifies again; an ack whose check stayed clear for `RECOVERY_GRACE` is dropped. Alerts that
start after the ack are not covered. Routes: `POST /agents/:hostname/ack|unack`.

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
- The New/Edit Alert Group form's four condition pickers are `<details>` elements
  wrapping plain checkbox groups, so the form submits without JS (the server reads the
  repeated `targets`/`services`/`statuses`/`events` params and renders each collapsed
  label itself). `alerts.js` only adds the live summary, filter, clear, one-open-at-a-time
  behaviour, and swapping the destination field to match the Alert Type.
- ECR paths in `render` are resolved relative to the CWD at compile time — build/run from
  the project root.

## Roadmap
- **Phase 1 (done):** dashboard + console, servers ordered by severity, msgpack ingest.
- **Phase 2:** agent groups (Prod/UAT) **done** — create/edit/delete groups, dashboard
  filters by group. Alert groups **done** as configuration: `/alert-groups` builds
  Monit-style rules (hosts/host groups × service × state × event -> alert type).
  Still open: actually **delivering** those alerts (exec/email/Slack), alert
  level/frequency control, multi-user accounts (needs schema/auth expansion).
- **Phase 3:** historical time-series metrics dashboards (CPU/RAM/filesystem). The agent
  already sends these metrics; we currently store only the latest — add history tables.

## Status / gotchas
- Nothing has been committed yet; the repo tree (`src/`, `spec/`, `shard.yml`, etc.) is
  untracked. Branch off `main` before committing.
- `spec/janehq_spec.cr` replaced the generated intentionally-failing placeholder with real
  tests; `spec/spec_helper.cr` requires only the pieces under test (not Kemal).
