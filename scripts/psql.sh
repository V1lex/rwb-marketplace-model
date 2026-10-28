#!/usr/bin/env bash
# =====================================================================
#  Обёртка над psql: один способ подключения для всех наших скриптов.
#
#  Если psql установлен локально — подключаемся к localhost напрямую
#  (параметры берутся из стандартных переменных PGHOST/PGPORT/...,
#  по умолчанию — база из docker-compose.yml организаторов).
#  Если psql нет — выполняем его внутри контейнера hack_postgres.
#  SQL всегда передаётся через stdin, поэтому работает в обоих случаях.
# =====================================================================
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-hack}"
export PGPASSWORD="${PGPASSWORD:-hack}"
export PGDATABASE="${PGDATABASE:-marketplace}"

if command -v psql >/dev/null 2>&1 && [ "${USE_DOCKER_PSQL:-0}" != "1" ]; then
  exec psql -X -v ON_ERROR_STOP=1 "$@"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$ROOT"
  exec docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$PGDATABASE" "$@"
fi
