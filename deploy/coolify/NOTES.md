# Deployment notes

How Canvas came to run on Coolify, and every problem met on the way: what it
looked like, what caused it, and what fixed it. `README.md` is how to run it;
this is why it is shaped the way it is.

Coolify 4.3, one server. Two Coolify applications in one project:

- **canvas-lms** — this repository, Docker Compose build pack, compose file
  `/docker-compose.coolify.yml`, deployed from `master` by a GitHub App webhook.
- **canvas-rce-api** — the `instructure/canvas-rce-api` image, pinned to
  `release-1.27.7`.

## How it was installed

1. **Read the upstream docs and code first.** The
   [Production Start](https://github.com/instructure/canvas-lms/wiki/Production-Start)
   guide lists the config files and rake tasks; the repository already ships
   `Dockerfile.production` (`RAILS_ENV=production`, assets compiled into the
   image), and Docker builds may include `docker-compose/config/`. So no Canvas
   code changes: only a compose file, config templates and a start script.
2. **`docker-compose.coolify.yml`** builds `Dockerfile.production` unchanged, so
   upstream updates need nothing redone. Five services: `migrate` (one-shot,
   `exclude_from_hc`), `web` and `jobs` (both wait for `migrate` to succeed),
   `postgres` (upstream's `docker-compose/postgres` image at Postgres 16, for
   pgvector and `pg_trgm`), `redis`.
3. **Config files are ERB templates reading the environment**
   (`deploy/coolify/config/*.yml`); `start.sh` copies them into `config/` at
   container start. Canvas's `ConfigFile` runs ERB on every file it loads.
4. **`start.sh migrate`** runs `db:initial_setup` when the database has no
   `accounts` table, `db:migrate` otherwise. `db:initial_setup` prompts
   interactively unless `CANVAS_LMS_ADMIN_EMAIL`, `CANVAS_LMS_ADMIN_PASSWORD`,
   `CANVAS_LMS_ACCOUNT_NAME` and `CANVAS_LMS_STATS_COLLECTION` are all set, and
   a prompt in a container hangs, so the script refuses to start without them.
5. **Secrets are Coolify's generated `SERVICE_PASSWORD_*` variables**, so none is
   in the repository. The two encryption keys must never change after the first
   deploy.
6. **The Coolify application was pointed at the new compose file** through the
   API (`PATCH /api/v1/applications/{uuid}` with `docker_compose_location`); the
   Coolify MCP has no field for it.
7. **Serving over HTTPS**: both applications on `https://` domains, Let's Encrypt
   through Coolify's Traefik, `CANVAS_SSL=true`.
8. **The RCE as a second resource** rather than a compose service: it is a
   prebuilt image, so it deploys in seconds without rebuilding Canvas.

## Problems and fixes

Roughly in the order they appeared.

### The first deploy crash-looped

- **Seen:** status `exited:unhealthy`, restart limit (10) reached, no logs —
  Coolify's API returns none for a stopped container.
- **Cause:** the application was deploying upstream's `docker-compose.yml`, which
  is the *development* setup: `RAILS_ENV=development`, no `config/*.yml` (the dev
  setup script copies them in), no database initialisation.
- **Fix:** the production compose file, templates and start script above.

### Rails could not open `log/production.log`

- **Seen:** `Permission denied @ rb_sysopen - /usr/src/app/log/production.log
  (Errno::EACCES)`; Passenger could not spawn the app; `/health_check` 500.
- **Cause:** `start.sh` symlinked the log to `/dev/stdout` so Coolify would show
  it. That works for anything the script runs itself, but Passenger spawns the
  app from nginx, which runs as root, so the app's stdout is a pipe root owns and
  the `docker` user cannot reopen it.
- **Fix:** `web` writes a real file and `start.sh` runs `tail -F` on it in the
  background; `migrate` and `jobs` keep the symlink.

### Every deploy failed in three seconds: "The string `https://` is no valid url"

- **Seen:** the deploy log stopped at that line, before any build.
- **Cause:** the compose file declared `SERVICE_FQDN_WEB: ${SERVICE_FQDN_WEB}`.
  Coolify treats `SERVICE_FQDN_*` / `SERVICE_URL_*` names in a compose file as
  instructions to generate a domain, and the self-reference left the value empty,
  so Coolify built the URL `https://` + nothing.
- **Fix:** Canvas reads its host from a plain `CANVAS_DOMAIN` variable set in
  Coolify. The domain therefore lives in two places — `web`'s domain in Coolify
  and `CANVAS_DOMAIN` — and both must change together.

### A build failed pulling the base image

- **Seen:** `failed to fetch anonymous token ... lookup auth.docker.io on
  127.0.0.11:53 ... i/o timeout`.
- **Cause:** DNS lookups from inside Docker on the server time out now and then.
- **Fix:** retrying the deploy. The underlying fix is on the server: give the
  Docker daemon reliable resolvers (on NixOS,
  `virtualisation.docker.daemon.settings.dns = [ "1.1.1.1" "9.9.9.9" ];`).
  Not done yet.

### Pages loaded, but nobody could sign in

- **Seen:** "Invalid Authenticity Token" on sign-in; the login page set no
  cookies at all.
- **Cause:** `config/environments/production.rb` sets `config.force_ssl = true`,
  which marks every cookie `secure`, and Rails does not send secure cookies over
  plain HTTP at all. Canvas production cannot be used over HTTP.
- **Fix:** HTTPS for both applications and `CANVAS_SSL=true`. (Canvas also
  evaluates `config/environments/production-*.rb`, where `force_ssl = false`
  would allow HTTP; rejected, because session cookies would then travel
  unencrypted.)

### Canvas got Traefik's default certificate instead of Let's Encrypt's

- **Seen:** `CN=TRAEFIK DEFAULT CERT` for Canvas while the RCE had a real one;
  Canvas itself answered correctly when certificate checks were skipped.
- **Cause, from the proxy log:** the first attempt could not resolve
  `acme-v02.api.letsencrypt.org` (the same Docker DNS timeouts as above); the
  automatic retry at midnight failed on Let's Encrypt's side resolving the
  sslip.io name (`DNS problem: networking error looking up A`). After that the
  proxy made no further attempt.
- **Fix:** restarting the Canvas application (no rebuild) made Traefik register
  the route again and request the certificate; it was issued within seconds.

### The RCE would not start

- **Seen:** `EnvRequiredException: Environment variable "STATSD_HOST" is required`.
- **Cause:** the RCE's README calls `STATSD_HOST` and `STATSD_PORT` optional;
  `config/stats.js` requires them.
- **Fix:** `127.0.0.1` and `8125`, as upstream Canvas's own dev setup uses —
  the metrics go nowhere. (The `wget: not found` lines in the same deploy log
  are Coolify's health-check fallback after `curl` got a 500, not a problem.)

## How Canvas and the RCE are connected

- The browser calls the RCE directly: Canvas puts its address in the page as
  `RICH_CONTENT_APP_HOST`, read from `dynamic_settings.yml`
  (`config.canvas.rich-content-service.app-host`) — so the RCE needs its own
  public HTTPS domain. Without the setting Canvas falls back to the literal
  string `"error"` (`lib/services/rich_content.rb`), and the editor's sidebar
  does not work.
- The two share two secrets. Canvas reads them as `canvas_security` from the
  `app-canvas/data/secrets` entry of `vault_contents.yml`, which
  `Canvas::Vault::FileClient` uses in place of a Vault server; the RCE takes
  them as `ECOSYSTEM_KEY` and `ECOSYSTEM_SECRET`.
- **The encryption secret is the AES-256-GCM key itself (`alg: dir`,
  `enc: A256GCM`) on both sides, so it must be exactly 32 bytes.** The template
  refuses to render otherwise. The values were generated locally and written to
  both applications through the Coolify API without being displayed.
- The RCE calls Canvas back on the domain inside the token, over HTTPS unless
  `HTTP_PROTOCOL_OVERRIDE=http` is set.
- `CIPHER_PASSWORD`, which upstream's dev compose file sets, is read nowhere in
  the current RCE code.

**Verified end to end:** signed in as the site admin; account settings carried
`RICH_CONTENT_APP_HOST` and a token; the RCE's `/api/session` accepted the token
(the secrets match) and `/api/documents` returned data it fetched from Canvas
(the RCE can reach Canvas). The sidebar has not been opened in a browser yet.

## Coolify behaviour worth knowing

- Build-time variables are passed to the image build as `ARG`s (the deploy log
  says "Added 14 ARG declarations"), secrets included, and Docker records
  argument values in the image history. Mark secrets runtime-only.
- The API hides variable values unless the token has `read:sensitive`, and a
  token without it gets empty strings — not an error — for every value.
- An application's API only returns logs for running containers, and a
  deployment's log only when the token may read it.
- Traefik does not route to a container until its health check passes; `web`
  takes about five minutes to boot, and until then the domain answers 404.
- Every push to `master` redeploys Canvas: several minutes of build and about
  five minutes of boot, even for a change to these notes.

## Still open

- Mark `SERVICE_PASSWORD_*` and `SMTP_PASSWORD` runtime-only (not build-time).
- Quieten the `jobs` log, which records the job-queue query every few seconds.
- Reliable DNS for Docker on the server.
- A real domain instead of sslip.io, for both applications.
- `files_domain`, LTI 1.3 keys, SMTP, and backups of the `canvas-files` and
  `pg-data` volumes.
