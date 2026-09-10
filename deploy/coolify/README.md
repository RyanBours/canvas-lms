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

- `CANVAS_LMS_ADMIN_EMAIL` — the first site administrator's login.
- `CANVAS_LMS_ACCOUNT_NAME` — optional, defaults to `Canvas`.

Optional:

- `CANVAS_DOMAIN` — overrides the domain Coolify assigned to `web`.
- `CANVAS_SSL=true` once the domain is served over HTTPS.
- `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM` —
  without `SMTP_ADDRESS` no mail is sent.

Canvas writes its domain into links and cookies, so changing the domain later
needs a redeploy and breaks links already sent out.

## Not set up

- A separate `files_domain` (recommended by the guide for user-uploaded content).
- LTI 1.3 keys in `dynamic_settings.yml`.
- The Rich Content Editor API service, Canvadocs, and Kaltura.
