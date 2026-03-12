# Tymeslot - Cloudron Deployment Guide

**Enterprise-grade meeting scheduling platform built with Elixir/Phoenix LiveView**

> For a comprehensive overview of Tymeslot's features and capabilities, see the [Core README](README.md).

## Overview

Tymeslot is designed to work seamlessly with Cloudron's managed infrastructure. This deployment method provides:

- **Automatic SSL/TLS management** via Cloudron's reverse proxy
- **Built-in PostgreSQL database** with automatic backups
- **Domain management** and DNS configuration
- **Automatic updates** and health monitoring
- **Single sign-on** integration with Cloudron users

---

## Prerequisites

- **Cloudron Server** (version 5.3.0 or higher)
- **Admin access** to your Cloudron dashboard
- **Domain name** configured in Cloudron

---

## Installation

Tymeslot is distributed as a community app. Install it directly from the Cloudron dashboard — no Docker or local build tools required.

### Via Dashboard (Recommended)

1. Open your Cloudron dashboard and go to **App Store**
2. Click **Install via URL**
3. Paste the following URL:
   ```
   https://raw.githubusercontent.com/Tymeslot/tymeslot/main/apps/tymeslot/CloudronVersions.json
   ```
4. Choose a location (e.g. `tymeslot.yourdomain.com`) and click **Install**
5. Once running, set the required environment variables (see below)

### Required Environment Variables

After installation, set these via the dashboard **Environment** tab or CLI:

```bash
SECRET=$(openssl rand -base64 64 | tr -d '\n')
cloudron env set --app tymeslot.yourdomain.com \
  SECRET_KEY_BASE=$SECRET \
  PHX_HOST=tymeslot.yourdomain.com \
  PORT=4000
```

### Accessing Your Installation

Once deployed, Tymeslot will be available at:
- **URL**: `https://tymeslot.yourdomain.com` (or your configured subdomain)
- **SSL**: Automatically configured by Cloudron

---

## Configuration

### Environment Variables

Cloudron automatically provides these variables:
- `CLOUDRON_POSTGRESQL_*` — Database connection details
- `CLOUDRON_MAIL_*` — Sendmail addon (email relay, auto-detected)
- `CLOUDRON_OIDC_*` — OIDC addon (SSO, auto-detected)
- `DEPLOYMENT_TYPE=cloudron` — Set automatically

### Adding Variables After Installation

To add or change variables after the app is running, use `cloudron env set`.
Multiple variables can be passed in a single command — the app restarts automatically.

```bash
cloudron env set --app tymeslot.yourdomain.com KEY=value KEY2=value2
```

To inspect current values:

```bash
cloudron env list --app tymeslot.yourdomain.com
```

### Optional Configuration

#### OAuth Providers

**GitHub OAuth:**
```bash
cloudron env set --app tymeslot.yourdomain.com ENABLE_GITHUB_AUTH=true GITHUB_CLIENT_ID=your_github_client_id GITHUB_CLIENT_SECRET=your_github_client_secret
```

**Google OAuth:**
```bash
GOOGLE_STATE=$(openssl rand -base64 32 | tr -d '\n')
cloudron env set --app tymeslot.yourdomain.com ENABLE_GOOGLE_AUTH=true GOOGLE_CLIENT_ID=your_google_client_id GOOGLE_CLIENT_SECRET=your_google_client_secret GOOGLE_STATE_SECRET=$GOOGLE_STATE
```

**Microsoft OAuth:**
```bash
OUTLOOK_STATE=$(openssl rand -base64 32 | tr -d '\n')
cloudron env set --app tymeslot.yourdomain.com OUTLOOK_CLIENT_ID=your_outlook_client_id OUTLOOK_CLIENT_SECRET=your_outlook_client_secret OUTLOOK_STATE_SECRET=$OUTLOOK_STATE
```

#### Cloudron Addon Integration

Tymeslot automatically detects and uses Cloudron's built-in addons:

- **Email (Sendmail Addon):** Cloudron's mail relay is used by default — no `SMTP_*` or `EMAIL_ADAPTER` configuration needed. The sender address and name are auto-configured.
- **Single Sign-On (OIDC Addon):** Cloudron's identity provider is enabled automatically — users see an "SSO" button on the login page. No `OAUTH_*` configuration needed.

To override the defaults:
- **Email:** Set `EMAIL_ADAPTER` explicitly (e.g., `EMAIL_ADAPTER=postmark`) to use an external provider instead of Cloudron's relay.
- **SSO:** Set `ENABLE_OAUTH_AUTH=false` to disable SSO, or set `ENABLE_OAUTH_AUTH=true` with your own `OAUTH_*` variables to use a different IdP.

If you're happy with Cloudron's built-in email and SSO, you can skip sections 3 (Email Configuration) and the Generic OAuth/OIDC setup below.

#### 3. Email Configuration (Optional Override)

**Option A: Postmark (Recommended)**
```bash
cloudron env set --app tymeslot.yourdomain.com EMAIL_ADAPTER=postmark EMAIL_FROM_NAME=Tymeslot EMAIL_FROM_ADDRESS=noreply@yourdomain.com POSTMARK_API_KEY=your_postmark_api_key
```

**Option B: SMTP**
```bash
cloudron env set --app tymeslot.yourdomain.com EMAIL_ADAPTER=smtp EMAIL_FROM_NAME=Tymeslot EMAIL_FROM_ADDRESS=noreply@yourdomain.com SMTP_HOST=your_smtp_host SMTP_PORT=587 SMTP_USERNAME=your_smtp_username SMTP_PASSWORD=your_smtp_password
```


---

## Setting Environment Variables

Use the Cloudron CLI to set variables. Multiple variables can be passed in a single command and the app restarts automatically:

```bash
cloudron env set --app tymeslot.yourdomain.com VAR_ONE=value VAR_TWO=value
```

To inspect current values:

```bash
cloudron env list --app tymeslot.yourdomain.com
```


---

## OAuth Provider Setup

### Google OAuth Setup

1. **Create Google Cloud Project**
   - Go to [Google Cloud Console](https://console.cloud.google.com/)
   - Create a new project or select existing one

2. **Enable APIs**
   ```
   - Google Calendar API
   - Google Meet API (if using Google Meet integration)
   ```

3. **Create OAuth Credentials**
   - Go to **APIs & Services** → **Credentials**
   - Click **Create Credentials** → **OAuth 2.0 Client IDs**
   - Application type: **Web application**
   - Authorized redirect URIs:
     ```
     https://tymeslot.yourdomain.com/auth/google/callback
     ```

### GitHub OAuth Setup

1. **Create GitHub App**
   - Go to **Settings** → **Developer settings** → **OAuth Apps**
   - Click **New OAuth App**

2. **Configure Application**
   ```
   Application name: Tymeslot
   Homepage URL: https://tymeslot.yourdomain.com
   Authorization callback URL: https://tymeslot.yourdomain.com/auth/github/callback
   ```

### Microsoft OAuth Setup (Outlook Calendar & Teams)

**Important**: Both Outlook Calendar and Microsoft Teams use the **same** OAuth app. Configure this once to enable both integrations.

1. **Create Azure AD App Registration**
   - Go to [Azure Portal](https://portal.azure.com/)
   - Navigate to **Microsoft Entra ID** (formerly Azure Active Directory)
   - Go to **App registrations** → **New registration**

2. **Configure Application**
   ```
   Name: Tymeslot
   Supported account types: Accounts in any organizational directory and personal Microsoft accounts
   ```

3. **Configure Redirect URIs**
   - Under **Authentication** → **Platform configurations** → **Add a platform** → **Web**
   - Add BOTH redirect URIs:
     ```
     https://tymeslot.yourdomain.com/auth/outlook/calendar/callback
     https://tymeslot.yourdomain.com/auth/teams/video/callback
     ```
   - Save the configuration

4. **Configure API Permissions**
   - Go to **API permissions** → **Add a permission** → **Microsoft Graph**
   - Select **Delegated permissions** and add:
     ```
     Calendars.ReadWrite
     User.Read
     offline_access
     openid
     profile
     ```
   - Click **Add permissions**
   - (Optional) Click **Grant admin consent** if deploying for an organization

5. **Create Client Secret**
   - Go to **Certificates & secrets** → **Client secrets** → **New client secret**
   - Add a description (e.g., "Tymeslot Production")
   - Choose an expiration period
   - Copy the **Value** (this is your `OUTLOOK_CLIENT_SECRET`) - you won't be able to see it again!

6. **Get Application (client) ID**
   - Go to **Overview**
   - Copy the **Application (client) ID** (this is your `OUTLOOK_CLIENT_ID`)

7. **Set Environment Variables in Cloudron**
   ```bash
   OUTLOOK_CLIENT_ID=<your_application_client_id>
   OUTLOOK_CLIENT_SECRET=<your_client_secret_value>
   OUTLOOK_STATE_SECRET=$(openssl rand -base64 32 | tr -d '\n')  # Self-generated
   ```

---

## Database Management

### Automatic Backups
- Cloudron automatically backs up your PostgreSQL database
- Backups are stored according to your Cloudron backup configuration
- No manual database management required

### Database Access (if needed)
```bash
# Access via Cloudron CLI
cloudron exec --app tymeslot.yourdomain.com -- psql $CLOUDRON_POSTGRESQL_URL
```

---

## File Storage

### User Uploads
- **Avatar images** and other uploads are stored in `/app/data/uploads`
- Cloudron automatically backs up this directory
- Files persist across app restarts and updates

---

## Monitoring and Logs

### Access Logs
```bash
# View application logs
cloudron logs --app tymeslot.yourdomain.com

# Follow logs in real-time
cloudron logs --app tymeslot.yourdomain.com --follow
```

### Health Monitoring
- Cloudron automatically monitors app health via `/healthcheck` endpoint
- Automatic restart on failure
- Email notifications for downtime (configurable)

---

## Updates

Cloudron checks for new versions automatically. When a new release is published, you will see an update prompt in the dashboard. Apply it with one click or via CLI:

```bash
cloudron update --app tymeslot.yourdomain.com
```

---

## Troubleshooting

### Common Issues

#### 1. App Won't Start
```bash
# Check logs for errors
cloudron logs --app tymeslot.yourdomain.com

# Common causes:
# - Missing SECRET_KEY_BASE
# - Invalid database connection
# - Missing required environment variables
```

#### 2. OAuth Not Working
```bash
# Verify redirect URLs match exactly:
# https://tymeslot.yourdomain.com/auth/provider/callback

# Check environment variables are set correctly
# Ensure PHX_HOST matches your domain
```

#### 3. Email Not Sending
```bash
# Test email configuration
# Check SMTP/Postmark credentials
# Verify FROM email domain is configured
```

#### 4. Database Issues
```bash
# Run database migrations manually
cloudron exec --app tymeslot.yourdomain.com -- bin/tymeslot eval "Tymeslot.Release.migrate()"

# Check database connection
cloudron exec --app tymeslot.yourdomain.com -- bin/tymeslot remote
```

### Performance Optimization

#### 1. Resource Allocation
- **Memory**: Minimum 512MB, recommended 1GB+
- **CPU**: 1+ cores recommended for multiple users
- Configure via Cloudron **Resources** tab

#### 2. Database Optimization
```bash
# Check database pool size (default: 100)
DATABASE_POOL_SIZE=50  # Reduce for smaller instances
```

---

## Security Considerations

### SSL/TLS
- **Automatic SSL** via Cloudron's reverse proxy
- **HSTS headers** enabled by default
- **Secure cookies** in production

### Database Security
- **Automatic encryption** of sensitive credentials
- **Network isolation** via Cloudron's container networking
- **Regular security updates** via Cloudron

### Authentication
- **Rate limiting** on authentication endpoints
- **Account lockout** after failed attempts
- **Secure password hashing** with bcrypt

---

## Support

### Getting Help
- **Documentation**: Check this guide and application logs
- **Cloudron Community**: [Cloudron Forum](https://forum.cloudron.io/)
- **Issues**: Report bugs via GitHub Issues

### Useful Commands
```bash
# App status
cloudron status --app tymeslot.yourdomain.com

# Restart app
cloudron restart --app tymeslot.yourdomain.com

# Access app shell
cloudron exec --app tymeslot.yourdomain.com -- /bin/bash

# Database console
cloudron exec --app tymeslot.yourdomain.com -- bin/tymeslot remote
```

---

## Next Steps

1. **Complete OAuth setup** for your preferred providers
2. **Configure email** for notifications and invitations
3. **Set up your profile** and availability preferences
4. **Create meeting types** for different appointment durations
5. **Share your booking link**: `https://tymeslot.yourdomain.com/your-username`
