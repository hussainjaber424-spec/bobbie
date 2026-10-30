#!/usr/bin/env bash
# Recreates a scratch database, applies shim + migrations, runs checks.
set -euo pipefail
cd "$(dirname "$0")/.."
DB=mcc_test
su postgres -c "dropdb --if-exists $DB && createdb $DB"
run() { PGOPTIONS="-c client_min_messages=warning" su postgres -c "PGOPTIONS='-c client_min_messages=warning' psql -q -X --set=client_min_messages=warning -v ON_ERROR_STOP=1 -d $DB -f '$1'"; }
run tests/00_supabase_shim.sql
for f in migrations/*.sql; do run "$f"; done
for f in migrations/*.sql; do run "$f"; done   # second pass: migrations must be re-runnable
run tests/10_permissions_and_workflow.sql
