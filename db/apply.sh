#!/usr/bin/env bash
# Applies the database migrations, dev seed, or SQL tests.
#
#   db/apply.sh migrations   apply db/migrations/*.sql in filename order
#   db/apply.sh seed         apply db/seeds/*.sql (dev and staging only)
#   db/apply.sh tests        run db/tests/*.sql (each file raises on failure)
#
# Target:
#   default                  the local compose database (`docker compose` in the
#                            Grogu root, service `db`)
#   DATABASE_URL=...         any database reachable with psql. Seeds refuse to run
#                            against it unless ALLOW_REMOTE_SEED=1 is set.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(cd "$HERE/../.." && pwd)"
ACTION="${1:-}"

run_sql() {
  local file="$1"
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$file"
  else
    (cd "$COMPOSE_DIR" && docker compose exec -T db \
      psql -U grogu -d grogu -v ON_ERROR_STOP=1 -q) < "$file"
  fi
}

case "$ACTION" in
  migrations)
    for f in "$HERE"/migrations/*.sql; do
      echo "migrate: $(basename "$f")"
      run_sql "$f"
    done
    ;;
  seed)
    if [ -n "${DATABASE_URL:-}" ] && [ "${ALLOW_REMOTE_SEED:-0}" != "1" ]; then
      echo "Refusing to seed DATABASE_URL: seeds are for local/dev databases only." >&2
      echo "Set ALLOW_REMOTE_SEED=1 if you are certain this is a dev database." >&2
      exit 1
    fi
    for f in "$HERE"/seeds/*.sql; do
      echo "seed: $(basename "$f")"
      run_sql "$f"
    done
    ;;
  tests)
    for f in "$HERE"/tests/*.sql; do
      echo "test: $(basename "$f")"
      run_sql "$f"
    done
    echo "all database tests passed"
    ;;
  *)
    echo "usage: $0 {migrations|seed|tests}" >&2
    exit 2
    ;;
esac
