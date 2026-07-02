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
DATABASE_HOST=${DATABASE_HOST:-localhost}
DATABASE_PORT=${DATABASE_PORT:-5432}

# The Postgres cluster lives in a subdirectory of the mounted volume.
# initdb needs to own and chmod 700 its data dir; using a subdirectory means
# the postgres user only touches a directory it creates itself, side-stepping
# hostile mount-root ownership on Docker Desktop, rootless Docker,
# userns-remap, and host bind-mounts.
PG_MOUNT=/var/lib/postgresql/data
PGDATA=$PG_MOUNT/pgdata

# ==================== SECTION 2: Validate Critical Configuration ====================
# Validate all required environment variables are set
# Fail fast with clear error messages if any are missing

MISSING_VARS=""

if [ -z "${SECRET_KEY_BASE:-}" ]; then
    MISSING_VARS="${MISSING_VARS}  - SECRET_KEY_BASE\n"
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

# ==================== SECTION 2B: Detect Database Configuration ====================
# Check if using external database or embedded PostgreSQL.
# External mode is selected solely by DATABASE_HOST pointing somewhere other than
# this container. The app (config/runtime.exs) reads discrete variables
# (DATABASE_HOST, DATABASE_PORT, POSTGRES_DB/USER/PASSWORD) — it does NOT read
# DATABASE_URL, so we must not branch on it here or we would skip the embedded
# database while the app still tries (and fails) to reach localhost.
USING_EXTERNAL_DB=false
if [ "$DATABASE_HOST" != "localhost" ] && [ "$DATABASE_HOST" != "127.0.0.1" ]; then
    USING_EXTERNAL_DB=true
    echo "✓ External database detected: $DATABASE_HOST:$DATABASE_PORT"
    echo "  Skipping embedded PostgreSQL initialization"
fi

# Warn loudly if DATABASE_URL is set: it is silently ignored by this deployment,
# so a user expecting it to point at an external database would otherwise get the
# embedded database with no indication anything was wrong.
if [ -n "${DATABASE_URL:-}" ] && [ "$USING_EXTERNAL_DB" = false ]; then
    echo "⚠ DATABASE_URL is set but is NOT used by Tymeslot's Docker deployment."
    echo "  To use an external database, set DATABASE_HOST (plus DATABASE_PORT,"
    echo "  POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD) instead."
fi

echo ""

# ==================== SECTION 3: PostgreSQL Database Initialization ====================
# Check if PostgreSQL has already been initialized
# If not, perform first-time initialization and configuration
# SKIP this section if using an external database
if [ "$USING_EXTERNAL_DB" = false ]; then
    # Legacy layout migration: images prior to v0.100.9 stored the cluster
    # directly in $PG_MOUNT. Move that content into the new $PGDATA
    # subdirectory so existing self-hosters upgrade seamlessly.
    if [ -f "$PG_MOUNT/postgresql.conf" ] && [ ! -f "$PGDATA/postgresql.conf" ]; then
        echo "Migrating PostgreSQL data to subdirectory layout..."
        # Clean any half-finished prior migration attempt.
        rm -rf "$PG_MOUNT/.pgdata.migrating"
        mkdir "$PG_MOUNT/.pgdata.migrating"
        find "$PG_MOUNT" -mindepth 1 -maxdepth 1 \
            ! -name pgdata ! -name .pgdata.migrating \
            -exec mv {} "$PG_MOUNT/.pgdata.migrating/" \;
        # An empty pgdata/ may exist from a previous interrupted attempt.
        [ -d "$PGDATA" ] && rmdir "$PGDATA" 2>/dev/null || true
        mv "$PG_MOUNT/.pgdata.migrating" "$PGDATA"
        chown -R postgres:postgres "$PGDATA"
        chmod 700 "$PGDATA"
        echo "✓ Migration complete"
    fi

    if [ ! -f "$PGDATA/postgresql.conf" ]; then
        echo "PostgreSQL not initialized. Running first-time setup..."
        # initdb will chmod 700 its own data directory, so the directory must
        # be owned by postgres before it runs. We create the subdirectory as
        # root (who owns the mount root in every scenario we've seen) and hand
        # ownership to postgres — this works even when the mount root's
        # attributes are not ours to change (Docker Desktop bind-mounts,
        # rootless Docker, userns-remap, SELinux-labelled volumes).
        mkdir -p "$PGDATA"
        chown postgres:postgres "$PGDATA"
        chmod 700 "$PGDATA"
        if su - postgres -c "/usr/lib/postgresql/*/bin/initdb -D $PGDATA"; then
            echo "✓ PostgreSQL initialized successfully"
        else
            echo "✗ ERROR: PostgreSQL initialization failed!"
            exit 1
        fi

        # Configure PostgreSQL for Docker environment
        # Allow remote connections with MD5 password authentication
        echo "host all all 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"
        # Bind to localhost interface
        echo "listen_addresses = 'localhost'" >> "$PGDATA/postgresql.conf"
        # Use default PostgreSQL port
        echo "port = 5432" >> "$PGDATA/postgresql.conf"
        echo "✓ PostgreSQL configuration completed"
    else
        echo "✓ PostgreSQL already initialized"
    fi
fi

# ==================== SECTION 4: Start PostgreSQL Service ====================
# Only start embedded PostgreSQL if not using external database
if [ "$USING_EXTERNAL_DB" = false ]; then
    echo "Starting PostgreSQL service..."
    # Remove stale postmaster.pid from an unclean container shutdown.
    # In Docker, no PostgreSQL process survives a container stop, so any
    # existing PID file from a previous run is guaranteed stale.
    if [ -f "$PGDATA/postmaster.pid" ]; then
        echo "  Removing stale postmaster.pid..."
        rm -f "$PGDATA/postmaster.pid"
    fi
    # Start PostgreSQL daemon and log output to a file
    if su - postgres -c "/usr/lib/postgresql/*/bin/pg_ctl -D $PGDATA -l $PGDATA/logfile start"; then
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
            echo "Check $PGDATA/logfile for details"
            exit 1
        fi
        echo "  Waiting... ($RETRY_COUNT/$MAX_RETRIES)"
        sleep 1
    done

    echo "✓ PostgreSQL is ready and accepting connections!"
else
    echo "Waiting for external database to be ready..."
    RETRY_COUNT=0
    MAX_RETRIES=30
    until pg_isready -h "$DATABASE_HOST" -p "$DATABASE_PORT" > /dev/null 2>&1; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            echo "✗ ERROR: External database failed to respond after ${MAX_RETRIES} seconds!"
            echo "Check your DATABASE_HOST ($DATABASE_HOST) and DATABASE_PORT ($DATABASE_PORT) configuration"
            exit 1
        fi
        echo "  Waiting... ($RETRY_COUNT/$MAX_RETRIES)"
        sleep 1
    done

    echo "✓ External database is ready and accepting connections!"
fi

# ==================== SECTION 6: Database and User Setup ====================
# Create database user and database if they don't already exist
# Only needed for embedded PostgreSQL; external databases should be pre-configured
if [ "$USING_EXTERNAL_DB" = false ]; then
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
else
    echo "✓ Using external database (ensure it's pre-configured)"
fi

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
echo "  MIX_ENV: ${MIX_ENV:-not set (will default to prod in release)}"
echo "  DEPLOYMENT_TYPE: ${DEPLOYMENT_TYPE:-docker}"
echo "  PHX_HOST: ${PHX_HOST}"
echo "  PORT: ${PORT}"
if [ "$USING_EXTERNAL_DB" = true ]; then
    echo "  Database: EXTERNAL ($DATABASE_HOST:$DATABASE_PORT)"
else
    echo "  Database: EMBEDDED (localhost:5432)"
    echo "  Database Name: ${POSTGRES_DB}"
    echo "  Database User: ${POSTGRES_USER}"
fi
echo "  EMAIL_ADAPTER: ${EMAIL_ADAPTER:-test}"
echo ""
echo "Security Configuration:"
echo "  SECRET_KEY_BASE: ✓ SET ($(echo -n "$SECRET_KEY_BASE" | wc -c) characters)"
echo ""
echo "Note: OAuth and calendar integrations are"
echo "      configured through the dashboard"
echo "========================================"
echo ""

# ==================== SECTION 9: Database Migrations ====================
# Run Ecto migrations to set up or update the database schema
# Must be run as 'app' user (for proper permissions)
# We export variables to the environment and use 'su -p' to preserve them,
# which prevents secrets from appearing in the process list (ps).
echo "========================================"
echo "Running database migrations..."
echo "========================================"

# Export all required environment variables for the app
export SECRET_KEY_BASE
export DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-docker}"
export PHX_HOST
export PORT
export POSTGRES_DB
export POSTGRES_USER
export POSTGRES_PASSWORD
export DATABASE_POOL_SIZE="${DATABASE_POOL_SIZE:-10}"
export EMAIL_ADAPTER="${EMAIL_ADAPTER:-test}"
export EMAIL_FROM_NAME="${EMAIL_FROM_NAME:-Tymeslot}"
export EMAIL_FROM_ADDRESS="${EMAIL_FROM_ADDRESS:-hello@localhost}"
export SMTP_HOST="${SMTP_HOST:-}"
export SMTP_PORT="${SMTP_PORT:-587}"
export SMTP_USERNAME="${SMTP_USERNAME:-}"
export SMTP_PASSWORD="${SMTP_PASSWORD:-}"
export POSTMARK_API_KEY="${POSTMARK_API_KEY:-}"
export GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:-}"
export GITHUB_CLIENT_SECRET="${GITHUB_CLIENT_SECRET:-}"
export GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
export GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
export WEBHOOK_BASE_URL="${WEBHOOK_BASE_URL:-}"
export ALLOW_PRIVATE_IPS_FOR_CALENDAR="${ALLOW_PRIVATE_IPS_FOR_CALENDAR:-false}"
export ALLOW_PRIVATE_IPS_FOR_WEBHOOKS="${ALLOW_PRIVATE_IPS_FOR_WEBHOOKS:-false}"
export ENABLE_GOOGLE_AUTH="${ENABLE_GOOGLE_AUTH:-false}"
export ENABLE_GITHUB_AUTH="${ENABLE_GITHUB_AUTH:-false}"

if su -p app -c "cd /app && bin/tymeslot eval 'Ecto.Migrator.with_repo(Tymeslot.Repo, &Ecto.Migrator.run(&1, :up, all: true))'"; then
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
# We use 'su -p' to preserve the exported environment variables.
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

export PHX_SERVER=true

# Start the server (this runs in foreground and blocks)
# We use exec to replace the shell process with the su process
exec su -p app -c "cd /app && bin/tymeslot start"

# If we reach here, the server has stopped (shouldn't happen in normal operation)
echo ""
echo "========================================"
echo "✗ WARNING: Phoenix server has stopped!"
echo "========================================"
exit 1
