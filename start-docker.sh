#!/bin/bash
#
# start-docker.sh - Initialize and start Tymeslot inside a Docker container
#
# This script runs inside the Docker container as the entry point. It:
#   1. Sets environment variables with sensible defaults
#   2. Validates required SECRET_KEY_BASE is set
#   3. Initializes PostgreSQL database (first run only)
#   4. Starts the PostgreSQL service
#   5. Creates database and user
#   6. Runs Ecto database migrations (passing all env vars to su command)
#   7. Starts the Phoenix web server (passing all env vars to su command)
#
# Important: All environment variables must be explicitly passed to 'su' commands
# because su creates a new shell that doesn't inherit parent environment variables.
#
# Note: This runs inside the container, NOT on the host machine

set -eu  # Exit on error and on undefined variables

# ==================== SECTION 1: Environment Variable Defaults ====================
# Set sensible defaults to avoid unbound variable errors when env vars are missing
# These can be overridden by passing -e flags to 'docker run'
POSTGRES_USER=${POSTGRES_USER:-tymeslot}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-tymeslot}
POSTGRES_DB=${POSTGRES_DB:-tymeslot}
PHX_HOST=${PHX_HOST:-localhost}
PORT=${PORT:-4000}

# ==================== SECTION 2: Validate Critical Configuration ====================
# Validate all required environment variables are set
# Fail fast with clear error messages if any are missing

MISSING_VARS=""

if [ -z "${SECRET_KEY_BASE:-}" ]; then
    MISSING_VARS="${MISSING_VARS}  - SECRET_KEY_BASE\n"
fi

if [ -z "${LIVE_VIEW_SIGNING_SALT:-}" ]; then
    MISSING_VARS="${MISSING_VARS}  - LIVE_VIEW_SIGNING_SALT\n"
fi

if [ -z "${SESSION_SIGNING_SALT:-}" ]; then
    MISSING_VARS="${MISSING_VARS}  - SESSION_SIGNING_SALT\n"
fi

if [ -n "$MISSING_VARS" ]; then
    echo "========================================"
    echo "✗ ERROR: Required environment variables are missing!"
    echo "========================================"
    echo ""
    echo "The following required variables are not set:"
    echo -e "$MISSING_VARS"
    echo ""
    echo "Generate secrets with:"
    echo "  openssl rand -base64 64 | tr -d '\\n'"
    echo ""
    echo "Then add them to your .env file:"
    echo "  SECRET_KEY_BASE=<generated_secret>"
    echo "  LIVE_VIEW_SIGNING_SALT=<generated_secret>"
    echo "  SESSION_SIGNING_SALT=<generated_secret>"
    echo ""
    echo "Or pass them via docker-compose.yml environment section."
    echo "Make sure docker-compose is reading your .env file!"
    echo "========================================"
    exit 1
fi

echo "✓ All required environment variables are set"

echo ""
echo "========================================"
echo "Starting Tymeslot (Docker deployment)"
echo "========================================"
echo ""

# ==================== SECTION 3: PostgreSQL Database Initialization ====================
# Check if PostgreSQL has already been initialized
# If not, perform first-time initialization and configuration
if [ ! -f /var/lib/postgresql/data/postgresql.conf ]; then
    echo "PostgreSQL not initialized. Running first-time setup..."
    # Run initdb to create the initial database cluster
    if su - postgres -c "/usr/lib/postgresql/*/bin/initdb -D /var/lib/postgresql/data"; then
        echo "✓ PostgreSQL initialized successfully"
    else
        echo "✗ ERROR: PostgreSQL initialization failed!"
        exit 1
    fi

    # Configure PostgreSQL for Docker environment
    # Allow remote connections with MD5 password authentication
    echo "host all all 0.0.0.0/0 md5" >> /var/lib/postgresql/data/pg_hba.conf
    # Bind to localhost interface
    echo "listen_addresses = 'localhost'" >> /var/lib/postgresql/data/postgresql.conf
    # Use default PostgreSQL port
    echo "port = 5432" >> /var/lib/postgresql/data/postgresql.conf
    echo "✓ PostgreSQL configuration completed"
else
    echo "✓ PostgreSQL already initialized"
fi

# ==================== SECTION 4: Start PostgreSQL Service ====================
echo "Starting PostgreSQL service..."
# Start PostgreSQL daemon and log output to a file
if su - postgres -c "/usr/lib/postgresql/*/bin/pg_ctl -D /var/lib/postgresql/data -l /var/lib/postgresql/data/logfile start"; then
    echo "✓ PostgreSQL service started"
else
    echo "✗ ERROR: Failed to start PostgreSQL service!"
    exit 1
fi

# ==================== SECTION 5: Wait for PostgreSQL Readiness ====================
# PostgreSQL needs time to start up; poll until it's ready to accept connections
echo "Waiting for PostgreSQL to be ready..."
RETRY_COUNT=0
MAX_RETRIES=30
until su - postgres -c "pg_isready -h localhost -p 5432" > /dev/null 2>&1; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "✗ ERROR: PostgreSQL failed to become ready after ${MAX_RETRIES} seconds!"
        echo "Check /var/lib/postgresql/data/logfile for details"
        exit 1
    fi
    echo "  Waiting... ($RETRY_COUNT/$MAX_RETRIES)"
    sleep 1
done

echo "✓ PostgreSQL is ready and accepting connections!"

# ==================== SECTION 6: Database and User Setup ====================
# Create database user and database if they don't already exist
# Using '|| true' to suppress errors if they already exist (idempotent)
echo "Setting up database user and database..."

# Create user (suppress error if already exists)
if su - postgres -c "psql -c \"CREATE USER ${POSTGRES_USER} WITH PASSWORD '$POSTGRES_PASSWORD';\"" 2>/dev/null; then
    echo "✓ Created database user: ${POSTGRES_USER}"
else
    echo "  User '${POSTGRES_USER}' already exists (OK)"
fi

# Create database (suppress error if already exists)
if su - postgres -c "psql -c \"CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};\"" 2>/dev/null; then
    echo "✓ Created database: ${POSTGRES_DB}"
else
    echo "  Database '${POSTGRES_DB}' already exists (OK)"
fi

# Grant privileges
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER};\"" >/dev/null 2>&1 || true
echo "✓ Database setup completed"

# ==================== SECTION 7: Application Data Directory Setup ====================
# Create required directories for timezone data and user uploads
echo "Setting up application data directories..."
mkdir -p /app/data/tzdata /app/data/uploads
# Set proper ownership so the 'app' user can write to these directories
chown -R app:app /app/data
echo "✓ Data directories ready"

# ==================== SECTION 8: Log Configuration (Non-Sensitive) ====================
# Display current configuration for debugging purposes
# Intentionally omit SECRET_KEY_BASE and database password for security
echo ""
echo "========================================"
echo "Environment Configuration:"
echo "========================================"
echo "  DEPLOYMENT_TYPE: ${DEPLOYMENT_TYPE:-docker}"
echo "  PHX_HOST: ${PHX_HOST}"
echo "  PORT: ${PORT}"
echo "  DATABASE: ${POSTGRES_DB}"
echo "  EMAIL_ADAPTER: ${EMAIL_ADAPTER:-test}"
echo ""
echo "Note: OAuth and calendar integrations are"
echo "      configured through the dashboard"
echo "========================================"
echo ""

# ==================== SECTION 9: Database Migrations ====================
# Run Ecto migrations to set up or update the database schema
# Must be run as 'app' user (for proper permissions)
# Must pass all required environment variables for Phoenix to initialize
echo "========================================"
echo "Running database migrations..."
echo "========================================"
if su app -c "cd /app && \
  SECRET_KEY_BASE='$SECRET_KEY_BASE' \
  SESSION_SIGNING_SALT='${SESSION_SIGNING_SALT:-}' \
  LIVE_VIEW_SIGNING_SALT='${LIVE_VIEW_SIGNING_SALT:-}' \
  DEPLOYMENT_TYPE='${DEPLOYMENT_TYPE:-docker}' \
  PHX_HOST='$PHX_HOST' \
  PORT='$PORT' \
  POSTGRES_DB='$POSTGRES_DB' \
  POSTGRES_USER='$POSTGRES_USER' \
  POSTGRES_PASSWORD='$POSTGRES_PASSWORD' \
  DATABASE_POOL_SIZE='${DATABASE_POOL_SIZE:-10}' \
  EMAIL_ADAPTER='${EMAIL_ADAPTER:-test}' \
  EMAIL_FROM_NAME='${EMAIL_FROM_NAME:-Tymeslot}' \
  EMAIL_FROM_ADDRESS='${EMAIL_FROM_ADDRESS:-hello@localhost}' \
  SMTP_HOST='${SMTP_HOST:-}' \
  SMTP_PORT='${SMTP_PORT:-587}' \
  SMTP_USERNAME='${SMTP_USERNAME:-}' \
  SMTP_PASSWORD='${SMTP_PASSWORD:-}' \
  POSTMARK_API_KEY='${POSTMARK_API_KEY:-}' \
  GITHUB_CLIENT_ID='${GITHUB_CLIENT_ID:-}' \
  GITHUB_CLIENT_SECRET='${GITHUB_CLIENT_SECRET:-}' \
  GOOGLE_CLIENT_ID='${GOOGLE_CLIENT_ID:-}' \
  GOOGLE_CLIENT_SECRET='${GOOGLE_CLIENT_SECRET:-}' \
  ENABLE_GOOGLE_AUTH='${ENABLE_GOOGLE_AUTH:-false}' \
  ENABLE_GITHUB_AUTH='${ENABLE_GITHUB_AUTH:-false}' \
  bin/tymeslot eval 'Ecto.Migrator.with_repo(Tymeslot.Repo, &Ecto.Migrator.run(&1, :up, all: true))'"; then
    echo "========================================"
    echo "✓ Database migrations completed successfully"
    echo "========================================"
else
    echo "========================================"
    echo "✗ ERROR: Database migrations failed!"
    echo "========================================"
    echo "This usually means:"
    echo "  - Database connection failed"
    echo "  - Missing required environment variables"
    echo "  - Migration syntax error"
    echo ""
    echo "Check the error output above for details."
    exit 1
fi

# ==================== SECTION 10: Start Phoenix Web Server ====================
# Start the Phoenix web server in foreground (important for Docker)
# Running in foreground allows Docker to monitor the process and manage the container lifecycle
# PHX_SERVER=true enables the web server (vs. just eval mode)
echo ""
echo "========================================"
echo "Starting Tymeslot Phoenix server..."
echo "========================================"
echo "Server will be available at:"
echo "  http://${PHX_HOST}:${PORT}"
echo ""
echo "If you see this message without errors above, startup was successful!"
echo "Check for 'Running TymeslotWeb.Endpoint' message below to confirm."
echo "========================================"
echo ""

# Start the server (this runs in foreground and blocks)
su app -c "cd /app && \
  SECRET_KEY_BASE='$SECRET_KEY_BASE' \
  SESSION_SIGNING_SALT='${SESSION_SIGNING_SALT:-}' \
  LIVE_VIEW_SIGNING_SALT='${LIVE_VIEW_SIGNING_SALT:-}' \
  DEPLOYMENT_TYPE='${DEPLOYMENT_TYPE:-docker}' \
  PHX_HOST='$PHX_HOST' \
  PORT='$PORT' \
  POSTGRES_DB='$POSTGRES_DB' \
  POSTGRES_USER='$POSTGRES_USER' \
  POSTGRES_PASSWORD='$POSTGRES_PASSWORD' \
  DATABASE_POOL_SIZE='${DATABASE_POOL_SIZE:-10}' \
  EMAIL_ADAPTER='${EMAIL_ADAPTER:-test}' \
  EMAIL_FROM_NAME='${EMAIL_FROM_NAME:-Tymeslot}' \
  EMAIL_FROM_ADDRESS='${EMAIL_FROM_ADDRESS:-hello@localhost}' \
  SMTP_HOST='${SMTP_HOST:-}' \
  SMTP_PORT='${SMTP_PORT:-587}' \
  SMTP_USERNAME='${SMTP_USERNAME:-}' \
  SMTP_PASSWORD='${SMTP_PASSWORD:-}' \
  POSTMARK_API_KEY='${POSTMARK_API_KEY:-}' \
  GITHUB_CLIENT_ID='${GITHUB_CLIENT_ID:-}' \
  GITHUB_CLIENT_SECRET='${GITHUB_CLIENT_SECRET:-}' \
  GOOGLE_CLIENT_ID='${GOOGLE_CLIENT_ID:-}' \
  GOOGLE_CLIENT_SECRET='${GOOGLE_CLIENT_SECRET:-}' \
  ENABLE_GOOGLE_AUTH='${ENABLE_GOOGLE_AUTH:-false}' \
  ENABLE_GITHUB_AUTH='${ENABLE_GITHUB_AUTH:-false}' \
  PHX_SERVER=true \
  bin/tymeslot start"

# If we reach here, the server has stopped (shouldn't happen in normal operation)
echo ""
echo "========================================"
echo "✗ WARNING: Phoenix server has stopped!"
echo "========================================"
exit 1
