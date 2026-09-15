# Canvas on Coolify

`docker-compose.coolify.yml` runs Canvas in production from the upstream
`Dockerfile.production`, following the
[Production Start](https://github.com/instructure/canvas-lms/wiki/Production-Start)
guide. Point the Coolify application's *Docker Compose Location* at
`/docker-compose.coolify.yml`; pushes to the deployed branch keep deploying.

| service    | does |
|------------|------|
| `migrate`  | runs once per deploy: `db:initial_setup` on an empty database, `db:migrate` after that |
| `web`      | nginx + Passenger on port 80, started after `migrate` succeeds |
| `jobs`     | delayed_job workers |
| `postgres` | Postgres 16 with pgvector and `pg_trgm`, from `docker-compose/postgres` |
| `redis`    | cache |

Uploaded files live in the `canvas-files` volume, the database in `pg-data`.
Back up both.

## Environment

Coolify generates and keeps these; do not change them after the first deploy:

- `SERVICE_PASSWORD_POSTGRES`
- `SERVICE_PASSWORD_64_ENCRYPTIONKEY`, `SERVICE_PASSWORD_64_JWTKEY` — changing
  either makes encrypted data in the database unreadable. Deleting and
  re-creating the Coolify application generates new ones.
- `SERVICE_PASSWORD_CANVASADMIN` — the first site administrator's password.

Set before the first deploy:

- `CANVAS_DOMAIN` — the host Canvas is served on, without a scheme. Keep it
  the same as the domain given to `web` in Coolify; the compose file cannot
  read that one (see the comment there).
- `CANVAS_LMS_ADMIN_EMAIL` — the first site administrator's login.
- `CANVAS_LMS_ACCOUNT_NAME` — optional, defaults to `Canvas`.

Serve Canvas over HTTPS, with `CANVAS_SSL=true`. `config/environments/production.rb`
sets `force_ssl`, so Canvas marks its session cookies `secure` and Rails does not
send them over plain HTTP at all: pages load, but nobody can sign in.

Optional:

- `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM` —
  without `SMTP_ADDRESS` no mail is sent.

The Rich Content Editor's sidebar (course files, images, uploads) is served by
`canvas-rce-api`, a separate Coolify application running the
`instructure/canvas-rce-api` image on its own domain:

- `RCE_HOST` — that application's URL, e.g. `https://canvas-rce.example.com`.
- `RCE_ENCRYPTION_SECRET` — exactly 32 bytes; the same value as the RCE's
  `ECOSYSTEM_KEY`.
- `RCE_SIGNING_SECRET` — the same value as the RCE's `ECOSYSTEM_SECRET`.

The RCE application also needs `NODE_ENV=production`, and `STATSD_HOST` and
`STATSD_PORT` (the code requires them although its README calls them optional;
`127.0.0.1` and `8125` send the metrics nowhere). Serve it over HTTPS like
Canvas: a browser will not call an HTTP service from an HTTPS page. It calls
Canvas back over HTTPS unless `HTTP_PROTOCOL_OVERRIDE=http` is set.

Canvas writes its domain into links and cookies, so changing the domain later
needs a redeploy and breaks links already sent out.

`NOTES.md` records how this deployment was set up and each problem met on the
way, with its cause and fix.

## Not set up

- A separate `files_domain` (recommended by the guide for user-uploaded content).
- LTI 1.3 keys in `dynamic_settings.yml`.
- Canvadocs and Kaltura.
