# Tymeslot - Docker Deployment Guide

**Enterprise-grade meeting scheduling platform built with Elixir/Phoenix LiveView**

> For a comprehensive overview of Tymeslot's features and capabilities, see the [Core README](README.md).

## Overview

Deploy Tymeslot using Docker with an embedded PostgreSQL database. This provides:

- **Single container** with embedded PostgreSQL
- **Volume persistence** for data and uploads
- **Easy deployment** on any Docker-compatible platform

---

## System Requirements

- **Docker** (version 20.10+ recommended)
- **500MB RAM** minimum (1GB+ recommended)
- **Domain name** (optional, for production use)

---

## Quick Start

### Pull and Run (Docker Hub Image)

If you want the quickest setup, pull and run the published image directly:

```bash
docker run -d \
  --name tymeslot \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')" \
  -e PHX_HOST=localhost \
  -e EMAIL_ADAPTER=smtp \
  -e EMAIL_FROM_NAME="Tymeslot" \
  -e EMAIL_FROM_ADDRESS="noreply@yourdomain.com" \
  -e SMTP_HOST="smtp.example.com" \
  -e SMTP_PORT=587 \
  -e SMTP_USERNAME="your-smtp-username" \
  -e SMTP_PASSWORD="your-smtp-password" \
  -v tymeslot_data:/app/data \
  -v tymeslot_pg:/var/lib/postgresql/data \
  luka1thb/tymeslot:latest
```

This will pull the image automatically if it is not present locally. For a pinned version, use `luka1thb/tymeslot:<VERSION>` (e.g., `luka1thb/tymeslot:0.97`).

**Note**: Email configuration is essential for production use (password resets, booking notifications, etc.). For development/testing only, you can omit email variables and the system will use a test adapter that logs emails to console instead of sending them.

### 1. Clone Repository

```bash
git clone https://github.com/tymeslot/tymeslot.git
cd tymeslot
```

### 2. Configure Environment

```bash
# Copy environment template
cp .env.example .env

# Generate required secrets
openssl rand -base64 64 | tr -d '\n'  # For SECRET_KEY_BASE
openssl rand -base64 32 | tr -d '\n'  # For POSTGRES_PASSWORD

# Edit .env and fill in the required values
nano .env
```

**Required Configuration** (`.env` file):

```bash
# REQUIRED: Must be at least 64 characters
SECRET_KEY_BASE=<paste_generated_secret>

# REQUIRED: Your domain (or "localhost" for testing)
PHX_HOST=localhost

# REQUIRED: Database credentials
POSTGRES_DB=tymeslot
POSTGRES_USER=tymeslot
POSTGRES_PASSWORD=<paste_generated_password>

# OPTIONAL: Port (defaults to 4000)
PORT=4000
```

### 3. Build and Run

#### Option A: Using the Build Script (Recommended)

```bash
# Run from project root
./build-docker.sh
```

The script will:
- Validate your `.env` configuration
- Build the Docker image
- Optionally start the container automatically

#### Option B: Using Docker Compose

```bash
docker compose up -d --build
```

#### Option C: Manual Docker Commands

```bash
# Build image
source .env
docker build -f Dockerfile.docker -t tymeslot .

# Run container
docker run -d \
  --name tymeslot \
  -p ${PORT:-4000}:4000 \
  --env-file .env \
  -v tymeslot_data:/app/data \
  -v postgres_data:/var/lib/postgresql/data \
  tymeslot
```

### 4. Access Your Installation

Wait 30-60 seconds for initialization, then visit:

- **URL**: `http://localhost:4000`

For production deployment with SSL/HTTPS, configure your reverse proxy (Nginx, Caddy, Traefik, etc.) separately.

---

## Understanding the Deployment Scripts

Tymeslot uses two scripts for Docker deployment:

### build-docker.sh (Host Machine)

Runs on your host machine to prepare and build the Docker image.

**Responsibilities**:
- Validates `.env` file exists
- Validates required environment variables
- Checks SECRET_KEY_BASE meets security requirements (64+ characters)
- Builds Docker image
- Optionally starts the container

**Usage**:
```bash
./build-docker.sh
```

### start-docker.sh (Container Entrypoint)

Runs automatically inside the container when it starts.

**Responsibilities**:
- Initializes PostgreSQL database (first run only)
- Starts PostgreSQL service
- Creates database and user
- Runs database migrations
- Starts Phoenix web server

**Note**: This script runs automatically - you never call it directly.

---

## Configuration

### Required Environment Variables

```bash
SECRET_KEY_BASE=<64+ characters>    # Generate with: openssl rand -base64 64 | tr -d '\n'
PHX_HOST=<your-domain-or-localhost>
POSTGRES_DB=tymeslot
POSTGRES_USER=tymeslot
POSTGRES_PASSWORD=<secure-password> # Generate with: openssl rand -base64 32 | tr -d '\n'
```

### Essential for Production

Email configuration is **required for production deployments** to enable:
- Password reset emails
- Booking confirmations and reminders
- Calendar event notifications
- User invitations

**Option 1: SMTP (recommended for most users)**
```bash
EMAIL_ADAPTER=smtp
EMAIL_FROM_NAME="Your Company"
EMAIL_FROM_ADDRESS=noreply@yourdomain.com
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=your-smtp-username
SMTP_PASSWORD=your-smtp-password
```

**Option 2: Postmark (recommended for high reliability)**
```bash
EMAIL_ADAPTER=postmark
EMAIL_FROM_NAME="Your Company"
EMAIL_FROM_ADDRESS=noreply@yourdomain.com
POSTMARK_API_KEY=your-postmark-api-key
```

**Development/Testing Only**: You can use `EMAIL_ADAPTER=test` to skip email configuration during development. Emails will be logged to console instead of being sent.

### HTTP Proxy Configuration

If your environment requires outbound HTTP requests to go through a proxy (common in corporate/secured environments), Tymeslot supports standard proxy environment variables:

**Standard Configuration (Recommended)**
```bash
# For HTTPS requests (most external APIs)
HTTPS_PROXY=http://username:password@proxy.example.com:3128

# For HTTP requests (if different from HTTPS)
HTTP_PROXY=http://username:password@proxy.example.com:3128

# Bypass proxy for specific hosts (comma-separated)
NO_PROXY=localhost,127.0.0.1,*.internal.company.com,10.0.0.0/8
```

**Environment Variable Details:**
- `HTTPS_PROXY` / `https_proxy` - Proxy for HTTPS requests (recommended)
- `HTTP_PROXY` / `http_proxy` - Proxy for HTTP requests
- `NO_PROXY` / `no_proxy` - Comma-separated list of hosts/patterns to bypass proxy

**NO_PROXY Patterns:**
- Exact hostname: `internal.example.com`
- Wildcard domain: `*.example.com` (matches any subdomain)
- CIDR notation: `10.0.0.0/8`, `192.168.0.0/16`
- Special: `*` (bypass proxy for all hosts)

**Example Configurations:**

Same proxy for HTTP and HTTPS:
```bash
HTTPS_PROXY=http://user:pass@proxy.company.com:3128
NO_PROXY=localhost,*.internal.company.com
```

Different proxies for HTTP and HTTPS:
```bash
HTTP_PROXY=http://user:pass@http-proxy.company.com:3128
HTTPS_PROXY=http://user:pass@https-proxy.company.com:3129
NO_PROXY=localhost,127.0.0.1,10.0.0.0/8
```

No authentication:
```bash
HTTPS_PROXY=http://proxy.company.com:8080
NO_PROXY=localhost,*.internal.company.com
```

**What Uses the Proxy:**

All outbound HTTP/HTTPS requests including:
- CalDAV calendar integrations (Nextcloud, Radicale, etc.)
- Google Calendar API
- Microsoft Outlook/Office 365 API
- Video provider APIs (Google Meet, Microsoft Teams)
- OAuth token exchanges
- All other external API calls

**Important**: If your proxy uses a whitelist-based access control, ensure the following domains are allowed:
- `www.googleapis.com` (Google Calendar, Google Meet)
- `graph.microsoft.com` (Outlook Calendar, Microsoft Teams)
- `oauth2.googleapis.com` (OAuth)
- Your CalDAV server domains
- Any custom video provider endpoints

### Using an External Database

By default, Tymeslot uses an embedded PostgreSQL database in the Docker container. To use an external database (e.g., from a cloud provider like AWS RDS, Azure Database, or DigitalOcean), set these variables:

```bash
DATABASE_HOST=your-db-host.example.com
DATABASE_PORT=5432
POSTGRES_DB=tymeslot
POSTGRES_USER=your_db_user
POSTGRES_PASSWORD=your_db_password
```

**Important**: When using an external database:
- The database and user must already exist
- Tymeslot will NOT create them automatically
- Ensure the database accepts connections from your Docker container's IP/network
- Network/firewall rules must allow the connection

The database detection is automatic:
- If `DATABASE_HOST` is `localhost` or `127.0.0.1`, uses embedded PostgreSQL
- If `DATABASE_HOST` is any other value, uses external database

### Optional Environment Variables

```bash
# Application
PORT=4000                    # HTTP port (default: 4000)
DATABASE_HOST=localhost      # Database host (default: localhost)
DATABASE_PORT=5432          # Database port (default: 5432)
DATABASE_POOL_SIZE=10        # DB pool size (default: 10)

# HTTP Proxy (for environments with restricted outbound access)
HTTP_PROXY=                  # Proxy for HTTP requests (e.g., http://user:pass@proxy.example.com:3128)
HTTPS_PROXY=                 # Proxy for HTTPS requests (e.g., http://user:pass@proxy.example.com:3128)
NO_PROXY=                    # Bypass proxy for these hosts (e.g., localhost,*.internal.com,10.0.0.0/8)

# OAuth Providers (optional - configure through dashboard after setup)
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_STATE_SECRET=         # Self-generated random string (required with Google OAuth)
OUTLOOK_CLIENT_ID=           # From Azure AD App Registration (used for both Outlook & Teams)
OUTLOOK_CLIENT_SECRET=       # From Azure AD App Registration (used for both Outlook & Teams)
OUTLOOK_STATE_SECRET=        # Self-generated random string (required with Microsoft OAuth)
ENABLE_GOOGLE_AUTH=false     # Enable Google login/signup
ENABLE_GITHUB_AUTH=false     # Enable GitHub login/signup
```

### Generate Secrets

```bash
# Generate SECRET_KEY_BASE (64+ characters)
openssl rand -base64 64 | tr -d '\n'

# Generate database password
openssl rand -base64 32 | tr -d '\n'

# Generate OAuth state secrets (for GOOGLE_STATE_SECRET, OUTLOOK_STATE_SECRET, etc.)
# Note: These are self-generated for security, NOT provided by Google/Microsoft
openssl rand -base64 32 | tr -d '\n'
```

---

## Common Commands

```bash
# View logs
docker logs -f tymeslot

# Stop container
docker stop tymeslot

# Start container
docker start tymeslot

# Restart container
docker restart tymeslot

# Remove container
docker stop tymeslot && docker rm tymeslot

# Shell access
docker exec -it tymeslot /bin/bash

# Access Elixir console
docker exec -it tymeslot bin/tymeslot remote
```

---

## Updates

### Update to Latest Version

```bash
# Pull latest code
git pull origin main

# Rebuild and restart
./build-docker.sh
```

Or with Docker Compose:

```bash
git pull origin main
docker compose down
docker compose up -d --build
```

---

## Troubleshooting

### Container Won't Start

```bash
# Check logs for errors
docker logs tymeslot

# Common causes:
# - Missing or invalid environment variables
# - SECRET_KEY_BASE too short (must be 64+ characters)
# - Port 4000 already in use
# - Insufficient disk space
```

**Verify configuration**:
```bash
source .env
echo "SECRET_KEY_BASE length: ${#SECRET_KEY_BASE}"  # Should be >= 64
echo "PHX_HOST: $PHX_HOST"
echo "POSTGRES_PASSWORD set: $([ -n "$POSTGRES_PASSWORD" ] && echo 'Yes' || echo 'No')"
```

### Container Starts But Can't Access Application

Wait 30-60 seconds for:
- PostgreSQL initialization
- Database migrations
- Phoenix server startup

Check startup progress:
```bash
docker logs -f tymeslot
```

Look for: `Running TymeslotWeb.Endpoint` message.

### Database Issues

```bash
# Check PostgreSQL is running
docker exec -it tymeslot ps aux | grep postgres

# Verify database connection
docker exec -it tymeslot su - postgres -c "psql -U $POSTGRES_USER -d $POSTGRES_DB -c 'SELECT version();'"

# Reset database (WARNING: Destroys all data)
docker volume rm postgres_data
```

### Port Already in Use

```bash
# Check what's using port 4000
sudo lsof -i :4000

# Either stop the conflicting service or change PORT in .env
PORT=8080  # Use a different port
```

### OAuth Not Working

- Verify redirect URLs exactly match the ones specified in the OAuth Setup section below
- Check PHX_HOST matches your domain
- Ensure credentials are correctly set in `.env`
- For Microsoft OAuth, ensure both redirect URIs are configured in Azure AD

---

## OAuth Provider Setup

Tymeslot supports multiple OAuth providers for authentication and calendar/video integrations. Configure the providers you need by following the setup guides below.

### Google OAuth Setup

**Used for**: Google Calendar integration, Google Meet video integration, Google login/signup

1. **Create Google Cloud Project**
   - Go to [Google Cloud Console](https://console.cloud.google.com/)
   - Create a new project or select existing one

2. **Enable Required APIs**
   - Go to **APIs & Services** → **Library**
   - Enable the following APIs:
     - Google Calendar API (required for calendar sync)
     - Google Meet API (required for Meet integration)

3. **Create OAuth Credentials**
   - Go to **APIs & Services** → **Credentials**
   - Click **Create Credentials** → **OAuth 2.0 Client IDs**
   - Configure OAuth consent screen if prompted
   - Application type: **Web application**
   - Add authorized redirect URI:
     ```
     https://your-domain.com/auth/google/callback
     ```
   - Click **Create** and copy the **Client ID** and **Client Secret**

4. **Configure Environment Variables**
   ```bash
   GOOGLE_CLIENT_ID=<your_google_client_id>
   GOOGLE_CLIENT_SECRET=<your_google_client_secret>
   GOOGLE_STATE_SECRET=$(openssl rand -base64 32 | tr -d '\n')  # Self-generated
   ENABLE_GOOGLE_AUTH=true  # Optional: Enable Google login/signup
   ```

### GitHub OAuth Setup

**Used for**: GitHub login/signup

1. **Create GitHub OAuth App**
   - Go to **Settings** → **Developer settings** → **OAuth Apps**
   - Click **New OAuth App**

2. **Configure Application**
   ```
   Application name: Tymeslot
   Homepage URL: https://your-domain.com
   Authorization callback URL: https://your-domain.com/auth/github/callback
   ```

3. **Configure Environment Variables**
   ```bash
   GITHUB_CLIENT_ID=<your_github_client_id>
   GITHUB_CLIENT_SECRET=<your_github_client_secret>
   ENABLE_GITHUB_AUTH=true  # Optional: Enable GitHub login/signup
   ```

### Microsoft OAuth Setup (Outlook Calendar & Teams)

**Important**: Both Outlook Calendar and Microsoft Teams use the **same** OAuth app. Configure this once to enable both integrations.

**Used for**: Outlook Calendar integration, Microsoft Teams video integration

1. **Create Azure AD App Registration**
   - Go to [Azure Portal](https://portal.azure.com/)
   - Navigate to **Microsoft Entra ID** (formerly Azure Active Directory)
   - Go to **App registrations** → **New registration**

2. **Configure Application**
   ```
   Name: Tymeslot
   Supported account types: Accounts in any organizational directory and personal Microsoft accounts
   Redirect URI: Leave blank for now (we'll add both URIs in the next step)
   ```
   - Click **Register**

3. **Configure Redirect URIs**
   - In your app registration, go to **Authentication**
   - Click **Add a platform** → **Web**
   - Add **BOTH** redirect URIs (both are required for full functionality):
     ```
     https://your-domain.com/auth/outlook/calendar/callback
     https://your-domain.com/auth/teams/video/callback
     ```
   - Under **Implicit grant and hybrid flows**, ensure **ID tokens** is checked
   - Click **Save**

4. **Configure API Permissions**
   - Go to **API permissions** → **Add a permission** → **Microsoft Graph**
   - Select **Delegated permissions** and add the following:
     ```
     Calendars.ReadWrite - Read and write to user calendars
     User.Read - Sign in and read user profile
     offline_access - Maintain access to data you have given it access to
     openid - Sign users in
     profile - View users' basic profile
     ```
   - Click **Add permissions**
   - (Optional) Click **Grant admin consent** if deploying for an organization

5. **Create Client Secret**
   - Go to **Certificates & secrets** → **Client secrets**
   - Click **New client secret**
   - Add a description (e.g., "Tymeslot Production")
   - Choose an expiration period (recommendation: 24 months, set a reminder to rotate before expiry)
   - Click **Add**
   - **Important**: Copy the **Value** immediately (this is your `OUTLOOK_CLIENT_SECRET`) - you won't be able to see it again!

6. **Get Application (client) ID**
   - Go to **Overview**
   - Copy the **Application (client) ID** (this is your `OUTLOOK_CLIENT_ID`)

7. **Configure Environment Variables**
   ```bash
   OUTLOOK_CLIENT_ID=<your_application_client_id>
   OUTLOOK_CLIENT_SECRET=<your_client_secret_value>
   OUTLOOK_STATE_SECRET=$(openssl rand -base64 32 | tr -d '\n')  # Self-generated
   ```

**Note**: The `STATE_SECRET` variables (GOOGLE_STATE_SECRET, OUTLOOK_STATE_SECRET) are self-generated random strings for security (CSRF protection). They are NOT provided by Google or Microsoft. Generate them using the openssl command shown above.

---

## Production Checklist

- [ ] **SSL/TLS certificate** configured (via reverse proxy)
- [ ] **Domain name** pointing to your server
- [ ] **Strong secrets** generated for all passwords and keys
- [ ] **Environment variables** validated and set correctly
- [ ] **Email service** configured (REQUIRED - Postmark or SMTP)
  - [ ] Test password reset functionality
  - [ ] Verify booking confirmation emails work
- [ ] **OAuth providers** configured (if needed)
- [ ] **Firewall** configured appropriately
- [ ] **Backups** scheduled for Docker volumes

---

## Support

### Getting Help

- **Check logs first**: `docker logs tymeslot`
- **GitHub Issues**: Report bugs and feature requests
- **Documentation**: Review error messages and this guide

### Useful Commands

```bash
# Container information
docker inspect tymeslot

# Container resource usage
docker stats tymeslot --no-stream

# Copy files to/from container
docker cp file.txt tymeslot:/app/
docker cp tymeslot:/app/logs/ ./logs/

# Check health
curl http://localhost:4000/healthcheck
```

---

## Next Steps

1. **Create your first user account**
2. **Test email functionality** (use "Forgot Password" to verify emails are working)
3. Configure your profile and availability
4. Connect calendar integrations (Google Calendar, Outlook)
5. Share your booking link: `http://your-domain.com/your-username`
6. Configure OAuth providers (optional)

---

**Congratulations!** 🎉 Tymeslot is now running in Docker.
