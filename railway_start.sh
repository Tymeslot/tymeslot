#!/bin/bash

# Railway deployment startup script.
# Mirrors start.sh (Cloudron) but uses the Nixpacks build path
# instead of the Cloudron /app/bin path.

set -eu

BIN=_build/prod/rel/tymeslot/bin/tymeslot

echo "==> Running database migrations"
$BIN eval 'Ecto.Migrator.with_repo(Tymeslot.Repo, &Ecto.Migrator.run(&1, :up, all: true))'

echo "==> Starting Phoenix server"
exec $BIN start
