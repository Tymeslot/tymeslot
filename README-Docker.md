# Tymeslot - Docker Deployment Guide

![Tymeslot Logo](https://via.placeholder.com/200x80/4F46E5/FFFFFF?text=Tymeslot)

**Enterprise-grade meeting scheduling with multi-provider calendar and video conferencing integration**

## Overview

This guide covers deploying Tymeslot using Docker with an embedded PostgreSQL database. This deployment method provides:

- **Single container** with embedded PostgreSQL
- **Full control** over your deployment environment
- **Flexible hosting** on any Docker-compatible platform
- **Volume persistence** for data and uploads
- **Custom domain** support

---

## Prerequisites

- **Docker** (version 20.10+ recommended)
- **Docker Compose** (optional, for easier management)
- **Domain name** pointing to your server
- **2GB+ RAM** recommended
- **SSL/TLS certificate** (Let's Encrypt, Cloudflare, etc.)

---

## Quick Start

### 1. Clone Repository

```bash
git clone https://github.com/yourusername/tymeslot.git
cd tymeslot
```

### 2. Configure Environment

```bash
# Copy environment template
cp .env.example .env

# Edit configuration and fill in required values
nano .env
```

### 3. Build and Run

Choose one of these methods:

#### Option A: Docker Compose (Recommended)
```bash
docker compose up -d --build
```

#### Option B: Build Script
```bash
./build-docker.sh

# The script will:
# - Validate all required environment variables
# - Build the Docker image
# - Optionally run the container automatically
```

#### Option C: Manual Build

```bash
# If you prefer manual control
source .env
docker build -f Dockerfile.docker -t tymeslot .

# Run container (detached)
docker run -d --name tymeslot -p ${PORT:-4000}:4000 \
  -e DEPLOYMENT_TYPE=docker \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e LIVE_VIEW_SIGNING_SALT="$LIVE_VIEW_SIGNING_SALT" \
  -e PHX_HOST="${PHX_HOST:-localhost}" \
  -e PORT="${PORT:-4000}" \
  -e POSTGRES_DB="${POSTGRES_DB:-tymeslot}" \
  -e POSTGRES_USER="${POSTGRES_USER:-tymeslot}" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e DATABASE_POOL_SIZE="${DATABASE_POOL_SIZE:-10}" \
  -v tymeslot_data:/app/data \
  -v postgres_data:/var/lib/postgresql/data \
  tymeslot
```

### 4. Access Your Installation

- **URL**: `http://your-domain.com:4000`
- **Setup SSL** using reverse proxy (Nginx, Caddy, Traefik)

---

## Understanding the Docker Scripts

Tymeslot includes two complementary shell scripts for Docker deployment. Understanding their roles is important for effective deployment management:

### build-docker.sh (Host Machine)

**Purpose**: Automates the pre-container setup and image building process

**Runs on**: Your host machine (not inside container)

**Responsibilities**:
- ✅ Validates `.env` file exists
- ✅ Validates all required environment variables (SECRET_KEY_BASE, PHX_HOST, PostgreSQL config)
- ✅ Checks SECRET_KEY_BASE meets minimum security requirements (64+ characters)
- ✅ Builds Docker image from `Dockerfile.docker`
- ✅ Interactively manages container lifecycle (stop existing, remove, start new)
- ✅ Provides user-friendly error messages and setup guidance

**When to use**:
- Initial setup and deployment
- Updating to new versions
- Any time you need to rebuild the image

**Example**:
```bash
./build-docker.sh
```

### start-docker.sh (Container Entrypoint)

**Purpose**: Initializes and starts services inside the Docker container

**Runs on**: Inside the container (as the container's entrypoint)

**Responsibilities**:
- ✅ Sets sensible environment variable defaults
- ✅ Validates SECRET_KEY_BASE is set
- ✅ Initializes PostgreSQL database (first run only)
- ✅ Starts PostgreSQL service
- ✅ Creates database and user if needed
- ✅ Runs Ecto database migrations
- ✅ Starts Phoenix web server in foreground

**When to use**: You don't call this directly - it runs automatically when the container starts

**Important**: This script must run in the foreground to keep the container alive

### Script Interaction Flow

```
Your Host Machine
  └─ ./build-docker.sh
     ├─ Validates .env
     ├─ Builds image
     └─ docker run → Container Starts
        └─ ./start-docker.sh (entrypoint)
           ├─ Initialize PostgreSQL
           ├─ Run migrations
           └─ Start Phoenix server
```

### Why Both Scripts Are Needed

1. **Separation of Concerns**: Pre-container validation and building is different from in-container service initialization
2. **Docker Best Practices**: Container images should be clean and reusable; entrypoints should focus on running services
3. **User Experience**: `build-docker.sh` provides helpful validation and guidance on the host side
4. **Flexibility**: You can rebuild the image without recreating containers, or start multiple containers from the same image

---

## Configuration

### Required Environment Variables

Edit your `.env` file with these required settings:

```bash
# REQUIRED: Must be at least 64 characters
# Generate with: openssl rand -base64 64 | tr -d '\n'
SECRET_KEY_BASE=
SESSION_SIGNING_SALT=
LIVE_VIEW_SIGNING_SALT=

# REQUIRED: Your domain name (e.g., tymeslot.yourdomain.com or localhost for local testing)
PHX_HOST=

# REQUIRED: Database configuration
POSTGRES_DB=tymeslot        # Database name (can customize)
POSTGRES_USER=tymeslot      # Database user (can customize)
POSTGRES_PASSWORD=          # Choose a secure password

# OPTIONAL: DB pool size (embedded Postgres defaults to 100 connections; Docker defaults to 10)
DATABASE_POOL_SIZE=10

# OPTIONAL: Port (defaults to 4000)
PORT=4000
```

### Generate Required Secrets

```bash
# Generate SECRET_KEY_BASE (generates 88 characters)
openssl rand -base64 64 | tr -d '\n'

# Generate LiveView signing salt
openssl rand -base64 32 | tr -d '\n'

# Generate secure database password
openssl rand -base64 32 | tr -d '\n'
```

### Important Notes

- **SECRET_KEY_BASE** must be at least 64 characters long
- **SESSION_SIGNING_SALT** and **LIVE_VIEW_SIGNING_SALT** are required at runtime
- **PHX_HOST** must match your domain exactly for OAuth callbacks to work
- **POSTGRES_DB** and **POSTGRES_USER** can be customized if needed
- **DATABASE_POOL_SIZE** defaults to 10 for Docker to avoid exhausting the embedded Postgres max_connections (100)
- **Email** defaults to local adapter (no external service needed)

### Optional Integrations

#### OAuth Providers

**GitHub OAuth:**
```bash
GITHUB_CLIENT_ID=your_github_client_id
GITHUB_CLIENT_SECRET=your_github_client_secret
```

**Google OAuth:**
```bash
GOOGLE_CLIENT_ID=your_google_client_id
GOOGLE_CLIENT_SECRET=your_google_client_secret
GOOGLE_STATE_SECRET=$(openssl rand -base64 32)
```

**Microsoft OAuth:**
```bash
OUTLOOK_CLIENT_ID=your_outlook_client_id
OUTLOOK_CLIENT_SECRET=your_outlook_client_secret
OUTLOOK_STATE_SECRET=$(openssl rand -base64 32)
```

#### Email Configuration

**Option A: Postmark (Recommended)**
```bash
EMAIL_ADAPTER=postmark
EMAIL_FROM_NAME="Your App Name"
EMAIL_FROM_ADDRESS=hello@your-domain.com
POSTMARK_API_KEY=your_postmark_api_key
```

**Option B: SMTP**
```bash
EMAIL_ADAPTER=smtp
EMAIL_FROM_NAME="Your App Name"
EMAIL_FROM_ADDRESS=hello@your-domain.com
SMTP_HOST=your_smtp_host
SMTP_PORT=587
SMTP_USERNAME=your_smtp_username
SMTP_PASSWORD=your_smtp_password
```


---

## Docker Compose Deployment (Recommended)

A `docker-compose.yml` file is included in the repository for easy deployment.

### Using Docker Compose

```bash
# Ensure your .env file is configured
cp .env.example .env
nano .env  # Fill in required values

# Build and start with Docker Compose
docker compose up -d --build

# Or if using older Docker Compose standalone
docker-compose up -d --build
```

**Note:** The docker-compose.yml file in the repository is pre-configured with all necessary settings.

### Docker Compose Commands

```bash
# View logs
docker compose logs -f

# Stop services
docker compose down

# Restart services
docker compose restart

# Rebuild and update
docker compose up -d --build
```

---

## Reverse Proxy Setup

### Nginx Configuration

```nginx
server {
    listen 80;
    server_name your-domain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name your-domain.com;

    # SSL Configuration
    ssl_certificate /path/to/your/certificate.crt;
    ssl_certificate_key /path/to/your/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;

    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";

    location / {
        proxy_pass http://localhost:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        
        # WebSocket support
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

### Caddy Configuration

```caddy
your-domain.com {
    reverse_proxy localhost:4000
    
    header {
        X-Frame-Options DENY
        X-Content-Type-Options nosniff
        X-XSS-Protection "1; mode=block"
        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    }
}
```

### Traefik Configuration

```yaml
# docker-compose.yml additions for Traefik
services:
  tymeslot:
    # ... existing configuration
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.tymeslot.rule=Host(`your-domain.com`)"
      - "traefik.http.routers.tymeslot.tls.certresolver=letsencrypt"
      - "traefik.http.services.tymeslot.loadbalancer.server.port=4000"
    networks:
      - traefik

networks:
  traefik:
    external: true
```

---

## OAuth Provider Setup

### Google OAuth Setup

1. **Create Google Cloud Project**
   - Go to [Google Cloud Console](https://console.cloud.google.com/)
   - Create a new project

2. **Enable APIs**
   - Google Calendar API
   - Google Meet API (optional)

3. **Create OAuth Credentials**
   - **Application type**: Web application
   - **Authorized redirect URIs**:
     ```
     https://your-domain.com/auth/google/callback
     ```

### GitHub OAuth Setup

1. **Create OAuth App**
   - Go to **Settings** → **Developer settings** → **OAuth Apps**
   - **Homepage URL**: `https://your-domain.com`
   - **Authorization callback URL**: `https://your-domain.com/auth/github/callback`

---

## Database Management

### Database Access

```bash
# Access PostgreSQL console (adjust user/db if you customized them)
docker exec -it tymeslot su - postgres -c "psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}"

# Run migrations manually (if needed)
docker exec -it tymeslot bin/tymeslot eval "Ecto.Migrator.with_repo(Tymeslot.Repo, &Ecto.Migrator.run(&1, :up, all: true))"

# Access Elixir console
docker exec -it tymeslot bin/tymeslot remote
```

### Database Backup

```bash
# Create backup (using your configured database user/name)
source .env
docker exec -it tymeslot su - postgres -c "pg_dump -U ${POSTGRES_USER} ${POSTGRES_DB}" > backup.sql

# Restore backup
docker exec -i tymeslot su - postgres -c "psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}" < backup.sql

# Automated backup script
#!/bin/bash
source .env
DATE=$(date +%Y%m%d_%H%M%S)
docker exec tymeslot su - postgres -c "pg_dump -U ${POSTGRES_USER} ${POSTGRES_DB}" | gzip > "backup_${DATE}.sql.gz"
```

---

## Monitoring and Logs

### View Logs

```bash
# Application logs
docker logs -f tymeslot

# Docker Compose logs
docker-compose logs -f

# Last 100 lines
docker logs --tail 100 tymeslot
```

### Health Monitoring

```bash
# Check health endpoint
curl http://localhost:4000/healthcheck

# Container status
docker ps | grep tymeslot

# Resource usage
docker stats tymeslot
```

### Log Rotation

Add to your system's logrotate configuration:

```bash
# /etc/logrotate.d/docker-tymeslot
/var/lib/docker/containers/*/*-json.log {
    daily
    rotate 30
    compress
    size 100M
    missingok
    notifempty
    create 644 root root
}
```

---

## Updates and Maintenance

### Update Application

```bash
# Pull latest code
git pull origin main

# Rebuild and restart using the build script
./build-docker.sh

# Or manually:
source .env
docker build -f Dockerfile.docker -t tymeslot .

# Stop old container
docker stop tymeslot
docker rm tymeslot

# Start new container
docker run -d --name tymeslot -p ${PORT:-4000}:4000 \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e PHX_HOST="$PHX_HOST" \
  -e POSTGRES_DB="$POSTGRES_DB" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -v tymeslot_data:/app/data \
  -v postgres_data:/var/lib/postgresql/data \
  tymeslot
```

### With Docker Compose

```bash
# Update and restart
git pull origin main
docker-compose build --no-cache
docker-compose up -d
```

### System Maintenance

```bash
# Clean up unused Docker resources
docker system prune -a

# Update system packages
sudo apt update && sudo apt upgrade

# Monitor disk usage
df -h
docker system df
```

---

## Troubleshooting

### Common Issues

#### 1. Container Won't Start

```bash
# Check logs for errors
docker logs tymeslot

# Common causes:
# - Missing required environment variables (PHX_HOST, SECRET_KEY_BASE, LIVE_VIEW_SIGNING_SALT, POSTGRES_*)
# - SECRET_KEY_BASE is too short (must be at least 64 characters)
# - Port 4000 already in use
# - Insufficient disk space
# - Database initialization failed

# Validate your environment:
source .env
echo "SECRET_KEY_BASE length: ${#SECRET_KEY_BASE}"  # Should be >= 64
echo "LIVE_VIEW_SIGNING_SALT length: ${#LIVE_VIEW_SIGNING_SALT}"  # Should be > 0
```

#### 2. Database Connection Issues

```bash
# Check PostgreSQL status inside container
docker exec -it tymeslot ps aux | grep postgres

# Test database connection (using your configured credentials)
source .env
docker exec -it tymeslot su - postgres -c "psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'SELECT version();'"

# Reset database (CAUTION: Destroys data)
docker volume rm postgres_data
```

#### 3. SSL/HTTPS Issues

```bash
# Verify reverse proxy configuration
# Check certificate validity
openssl x509 -in certificate.crt -text -noout

# Test SSL connection
curl -I https://your-domain.com
```

#### 4. OAuth Authentication Issues

```bash
# Verify redirect URLs exactly match:
# https://your-domain.com/auth/provider/callback

# Check environment variables
docker exec -it tymeslot env | grep -E "(GITHUB|GOOGLE|OUTLOOK)"

# Check PHX_HOST matches your domain
docker exec -it tymeslot env | grep PHX_HOST
```

#### 5. Email Not Working

```bash
# Test email configuration from container
docker exec -it tymeslot bin/tymeslot remote

# In Elixir console:
# Tymeslot.Mailer.deliver(test_email())
```

### Performance Optimization

#### Container Resources

```bash
# Run with resource limits
source .env
docker run -d --name tymeslot \
  --memory=1g \
  --cpus=1.0 \
  -p ${PORT:-4000}:4000 \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e PHX_HOST="$PHX_HOST" \
  -e POSTGRES_DB="$POSTGRES_DB" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -v tymeslot_data:/app/data \
  -v postgres_data:/var/lib/postgresql/data \
  tymeslot
```

#### Database Tuning

```bash
# Adjust database pool size for your needs
DATABASE_POOL_SIZE=50  # Lower for smaller instances
DATABASE_POOL_SIZE=200 # Higher for busy instances
```

---

## Security Considerations

### Container Security

```bash
# Run as non-root user (already configured in Dockerfile)
# Use specific image tags instead of 'latest'
# Regularly update base images

# Scan for vulnerabilities
docker scan tymeslot:docker
```

### Network Security

```bash
# Use Docker networks for isolation
docker network create tymeslot-network

# Run container on custom network
docker run --network tymeslot-network ...

# Firewall configuration (example with ufw)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw deny 4000/tcp  # Block direct access to app port
```

### Data Protection

```bash
# Encrypt volumes at rest (depends on your infrastructure)
# Regular backups to secure location
# Monitor access logs
# Use strong passwords and secrets
```

---

## Production Checklist

- [ ] **SSL/TLS certificate** configured and valid
- [ ] **Reverse proxy** properly configured
- [ ] **Domain name** pointing to your server
- [ ] **Environment variables** set correctly
- [ ] **OAuth providers** configured with correct redirect URLs
- [ ] **Email service** configured and tested
- [ ] **Database backups** automated
- [ ] **Log rotation** configured
- [ ] **Monitoring** and alerting set up
- [ ] **Firewall** configured to block direct access to port 4000
- [ ] **System updates** automated
- [ ] **Container resource limits** set appropriately

---

## Support

### Getting Help

- **Check logs first**: `docker logs tymeslot`
- **GitHub Issues**: Report bugs and feature requests
- **Documentation**: Review this guide and error messages
- **Community**: Docker community forums

### Useful Commands

```bash
# Container information
docker inspect tymeslot

# Copy files to/from container
docker cp file.txt tymeslot:/app/
docker cp tymeslot:/app/logs/ ./logs/

# Execute commands in container
docker exec -it tymeslot /bin/bash
docker exec -it tymeslot bin/tymeslot remote

# Container resource usage
docker stats tymeslot --no-stream
```

---

## Next Steps

1. **Set up SSL/TLS** with your reverse proxy
2. **Configure OAuth providers** for social authentication
3. **Set up email service** for notifications
4. **Create your first user account** and configure profile
5. **Share your booking link**: `https://your-domain.com/your-username`
6. **Set up automated backups** for database and uploads
7. **Configure monitoring** and alerting

---

**Congratulations!** 🎉 Tymeslot is now running on Docker with full control over your deployment environment.
