#!/bin/bash

set -eu

echo "==> Starting Tymeslot"

# Environment variables are set externally in production

# Create necessary directories for runtime
mkdir -p /app/data/tzdata /app/data/uploads
chmod -R 777 /app/data
echo "Created runtime directories:"
ls -la /app/data/

# Log environment (without sensitive data)
echo "Environment configured:"
echo "  PHX_HOST: ${PHX_HOST:-not set}"
echo "  PORT: ${PORT:-not set}"
echo "  Note: Calendar and video integrations are managed through the dashboard"

# Run database migrations
echo "Running database migrations..."
mix ecto.migrate

# Start the Phoenix server
echo "Starting Phoenix server..."
PHX_SERVER=true /app/_build/prod/rel/tymeslot/bin/tymeslot start