#!/usr/bin/env bash
# Entry point for the Canvas services in docker-compose.coolify.yml:
#   start.sh migrate | web | jobs
set -euo pipefail
cd /usr/src/app

# Config files are templates reading the environment; see deploy/coolify/config.
# The rest are the examples the Production Start guide copies unchanged.
cp deploy/coolify/config/*.yml config/
for name in external_migration vault_contents dynamic_settings; do
  [ -e "config/$name.yml" ] || cp "config/$name.yml.example" "config/$name.yml"
done

# Canvas logs to files; send them to the container output so Coolify shows them.
mkdir -p log
ln -sf /dev/stdout log/production.log
ln -sf /dev/stdout log/delayed_job.log

case "${1:-}" in
  migrate)
    # An empty database gets db:initial_setup (schema, default account, site
    # admin); every later deploy gets db:migrate. A failed connection stops here.
    initialised=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$CANVAS_DATABASE_HOST" \
      -U "$CANVAS_DATABASE_USERNAME" -d canvas_production -tAc \
      "SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename = 'accounts'")
    if [ "$initialised" = "1" ]; then
      exec bin/rails db:migrate
    fi
    : "${CANVAS_LMS_ADMIN_EMAIL:?is required for the first deploy}"
    : "${CANVAS_LMS_ADMIN_PASSWORD:?is required for the first deploy}"
    exec bin/rails db:initial_setup
    ;;
  web)
    bin/rails brand_configs:generate_and_upload_all
    exec /tini -- /usr/src/entrypoint
    ;;
  jobs)
    exec bundle exec script/delayed_job run
    ;;
  *)
    echo "usage: $0 migrate|web|jobs" >&2
    exit 64
    ;;
esac
