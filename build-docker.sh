#!/bin/bash
# build-docker.sh - Build and run Tymeslot Docker container
#
# This script:
#   1. Validates that a .env configuration file exists
#   2. Loads and validates all required environment variables from .env
#   3. Ensures signing salts and secrets are properly configured
#   4. Builds a Docker image using Dockerfile.docker
#   5. Optionally runs the Docker container with --env-file .env
#
# Required .env variables:
#   - SECRET_KEY_BASE (64+ chars)
#   - LIVE_VIEW_SIGNING_SALT
#   - SESSION_SIGNING_SALT
#   - PHX_HOST
#   - POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD

set -e  # Exit on any error

echo "========================================"
echo "Building Tymeslot Docker container"
echo "========================================"
echo ""

# ==================== SECTION 1: Environment File Validation ====================
# Check if .env file exists, as it's required for configuration
if [ ! -f .env ]; then
    echo "========================================"
    echo "✗ ERROR: .env file not found!"
    echo "========================================"
    echo ""
    echo "Please copy .env.example to .env and fill in required values:"
    echo ""
    echo "  cp .env.example .env"
    echo "  nano .env  # Edit the file"
    echo ""
    echo "You need to generate secrets for:"
    echo "  - SECRET_KEY_BASE"
    echo "  - LIVE_VIEW_SIGNING_SALT"
    echo "  - SESSION_SIGNING_SALT"
    echo ""
    echo "Use: openssl rand -base64 64 | tr -d '\\n'"
    echo "========================================"
    exit 1
fi

echo "✓ Found .env file"

# ==================== SECTION 2: Load Environment Variables ====================
# Source the .env file to make variables available to this script
# set -a exports all variables automatically, set +a turns it off
echo "Loading environment variables from .env..."
set -a  # Export all variables
source .env
set +a  # Stop exporting
echo "✓ Environment variables loaded"

# ==================== SECTION 3: Validate Required Variables ====================
# Collect any missing required environment variables in an array
echo ""
echo "Validating required environment variables..."
MISSING_VARS=()

# Check SECRET_KEY_BASE: must be set and at least 64 characters for Phoenix security
if [ -z "$SECRET_KEY_BASE" ]; then
    MISSING_VARS+=("SECRET_KEY_BASE")
elif [ ${#SECRET_KEY_BASE} -lt 64 ]; then
    echo "========================================"
    echo "✗ ERROR: SECRET_KEY_BASE too short!"
    echo "========================================"
    echo ""
    echo "Current length: ${#SECRET_KEY_BASE} characters"
    echo "Required: At least 64 characters"
    echo ""
    echo "Generate a proper key with:"
    echo "  openssl rand -base64 64 | tr -d '\\n'"
    echo "========================================"
    exit 1
fi

# Check PHX_HOST: required for Phoenix to know its hostname
if [ -z "$PHX_HOST" ]; then
    MISSING_VARS+=("PHX_HOST")
fi

# Check POSTGRES_DB: required database name for PostgreSQL
if [ -z "$POSTGRES_DB" ]; then
    MISSING_VARS+=("POSTGRES_DB")
fi

# Check POSTGRES_USER: required database user for PostgreSQL
if [ -z "$POSTGRES_USER" ]; then
    MISSING_VARS+=("POSTGRES_USER")
fi

# Check POSTGRES_PASSWORD: required database password for PostgreSQL
if [ -z "$POSTGRES_PASSWORD" ]; then
    MISSING_VARS+=("POSTGRES_PASSWORD")
fi

# Check LIVE_VIEW_SIGNING_SALT: required for Phoenix LiveView
if [ -z "$LIVE_VIEW_SIGNING_SALT" ]; then
    MISSING_VARS+=("LIVE_VIEW_SIGNING_SALT")
fi

# Check SESSION_SIGNING_SALT: required for Phoenix sessions
if [ -z "$SESSION_SIGNING_SALT" ]; then
    MISSING_VARS+=("SESSION_SIGNING_SALT")
fi

# If any variables are missing, report them and exit
if [ ${#MISSING_VARS[@]} -ne 0 ]; then
    echo "========================================"
    echo "✗ ERROR: Missing required environment variables!"
    echo "========================================"
    echo ""
    echo "Missing variables:"
    for var in "${MISSING_VARS[@]}"; do
        echo "  - $var"
    done
    echo ""
    echo "Please edit your .env file and set these variables."
    echo ""
    echo "Generate secure secrets with:"
    echo "  openssl rand -base64 64 | tr -d '\\n'"
    echo ""
    echo "You need to generate 3 different secrets for:"
    echo "  - SECRET_KEY_BASE"
    echo "  - LIVE_VIEW_SIGNING_SALT"
    echo "  - SESSION_SIGNING_SALT"
    echo ""
    echo "And one for:"
    echo "  - POSTGRES_PASSWORD (can use: openssl rand -base64 32)"
    echo "========================================"
    exit 1
fi

echo "✓ All required environment variables validated"

# ==================== SECTION 4: Build Docker Image ====================
echo ""
echo "========================================"
echo "Building Docker image..."
echo "========================================"
echo ""

# Build the Docker image from Dockerfile.docker and tag it as 'tymeslot'
docker build -f Dockerfile.docker -t tymeslot .

echo ""
echo "========================================"
echo "✓ Docker image built successfully!"
echo "========================================"

# ==================== SECTION 5: Interactive Container Startup ====================
# Ask the user if they want to start the container immediately
echo ""
read -p "Would you like to run Tymeslot now? (y/n): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "========================================"
    echo "Starting Tymeslot container..."
    echo "========================================"
    echo ""

    # Clean up any existing container with the same name to avoid conflicts
    # This allows re-running the script without manual cleanup
    if docker ps -a -q -f name=tymeslot | grep -q .; then
        echo "Cleaning up existing Tymeslot container..."
        docker stop tymeslot >/dev/null 2>&1 || true
        docker rm tymeslot >/dev/null 2>&1 || true
        echo "✓ Cleanup completed"
    fi
    
    # Run the Docker container in detached mode with configuration
    # -d: Run in background (detached mode)
    # --name tymeslot: Name the container for easy reference
    # -p: Map port 4000 (or PORT env var) from container to host
    # --env-file: Load all environment variables from .env file
    # -v: Mount Docker volumes for persistent data storage
    docker run -d \
        --name tymeslot \
        -p ${PORT:-4000}:4000 \
        --env-file .env \
        -v tymeslot_data:/app/data \
        -v postgres_data:/var/lib/postgresql/data \
        tymeslot
    
    # Display startup information and helpful next steps
    echo ""
    echo "========================================"
    echo "✓ Tymeslot container started!"
    echo "========================================"
    echo ""
    echo "Access your application at:"
    echo "  http://$PHX_HOST:${PORT:-4000}"
    echo ""
    echo "Note: Please wait 30-60 seconds for:"
    echo "  - PostgreSQL initialization"
    echo "  - Database migrations"
    echo "  - Phoenix server startup"
    echo ""
    echo "Useful commands:"
    echo "  View logs:    docker logs -f tymeslot"
    echo "  Stop:         docker stop tymeslot"
    echo "  Restart:      docker restart tymeslot"
    echo "  Shell access: docker exec -it tymeslot /bin/bash"
    echo "========================================"
else
    # User chose not to run the container; provide manual run command
    echo ""
    echo "========================================"
    echo "✓ Build complete!"
    echo "========================================"
    echo ""
    echo "To run Tymeslot manually:"
    echo ""
    echo "Using docker run:"
    echo "  docker run -d --name tymeslot \\"
    echo "    -p ${PORT:-4000}:4000 \\"
    echo "    --env-file .env \\"
    echo "    -v tymeslot_data:/app/data \\"
    echo "    -v postgres_data:/var/lib/postgresql/data \\"
    echo "    tymeslot"
    echo ""
    echo "Or using docker-compose (recommended):"
    echo "  docker-compose up -d"
    echo ""
    echo "========================================"
fi