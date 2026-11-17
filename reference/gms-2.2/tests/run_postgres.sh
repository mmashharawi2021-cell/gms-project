#!/usr/bin/env bash
set -euo pipefail
if ! command -v psql >/dev/null; then
  echo 'PostgreSQL client psql not installed. Integration tests NOT RUN.' >&2
  exit 3
fi
if [[ -z "${GMS_TEST_DATABASE_URL:-}" ]]; then
  echo 'Set GMS_TEST_DATABASE_URL to a disposable PostgreSQL 16+ database URL.' >&2
  exit 2
fi
script_dir="$(cd "$(dirname "$0")/.." && pwd)"
for f in 10_baseline.sql 20_hardening.sql 30_financial_engine.sql tests/pg_integration.sql; do
  echo "Applying/testing $f"
  psql "$GMS_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -X -f "$script_dir/$f"
done
