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

There are two ways to install Tymeslot on Cloudron:

### Option A: Community Package (Recommended)

Install via Cloudron's [community package system](https://forum.cloudron.io/topic/15046/update-on-community-packages). This gives you automatic update notifications and one-click upgrades — the same experience as official Cloudron apps.

1. Open your Cloudron dashboard and go to **App Store**
2. Click **Install via URL**
3. Paste the following URL:
   ```
   https://raw.githubusercontent.com/Tymeslot/tymeslot/main/CloudronVersions.json
   ```
4. Choose a location (e.g. `tymeslot.yourdomain.com`) and click **Install**

Cloudron handles the Docker image, health checks, and updates automatically. When a new version is published, you'll see an update prompt in the dashboard.

### Option B: Manual Docker Build

Build and install from source using the Cloudron CLI. Use this if you want to run a custom fork or a version not yet published to the community package.

1. Clone the repository and build the Docker image:
   ```bash
   git clone https://github.com/Tymeslot/tymeslot.git
   cd tymeslot
   docker build -t your-registry/tymeslot-cloudron:latest .
   docker push your-registry/tymeslot-cloudron:latest
   ```
2. Install using the Cloudron CLI:
   ```bash
   cloudron install --image your-registry/tymeslot-cloudron:latest
   ```

With this method you manage image builds and updates yourself. To update, rebuild the image and run `cloudron update --app tymeslot.yourdomain.com`.

### Required Environment Variables

After installation (either method), set these via the dashboard **Environment** tab or CLI:

```bash
SECRET=$(openssl rand -base64 64 | tr -d '\n')
cloudron env set --app tymeslot.yourdomain.com \
  SECRET_KEY_BASE=$SECRET \
  PHX_HOST=tymeslot.yourdomain.com \
  PORT=4000
```

> **Note:** `PHX_HOST` must match your Cloudron domain exactly. If unset, Tymeslot falls back to `CLOUDRON_APP_DOMAIN` (provided automatically by Cloudron), but setting it explicitly is recommended.

### Two Ways to Set Variables

You can configure environment variables in either of two ways. They can be mixed freely — values set via the Cloudron CLI take precedence over values from the `.env` file, so the file is best treated as a default that the CLI can override per-key.

**Option 1: Cloudron CLI / Dashboard (recommended for most operators)**

Use `cloudron env set` or the dashboard's **Environment** tab as shown above. Cloudron persists the values, restarts the app automatically, and surfaces them under `cloudron env list`. This is the simplest workflow and the only one that also exposes the values in the dashboard UI.

**Option 2: `.env` file in the data directory**

Tymeslot reads `/app/data/.env` at boot and applies any key that is not already set in the environment. This is convenient when you have many variables to manage, want to keep them under version control on your own host, or are scripting the deployment.

The file is created from the packaged variable reference with every value commented out, so it already contains the full documented list and nothing is enabled by it. On top of that, the variables this app already has set are copied into it, so it is a complete picture of your configuration rather than an empty form standing next to it. New installs get the file on first boot; an existing install gets it on the first boot after upgrading, unless it already holds settings of your own, in which case it is left exactly as it is.

```bash
# Edit the file directly inside the running container
cloudron exec --app tymeslot.yourdomain.com -- vi /app/data/.env

# Or copy a prepared file in from your workstation
cloudron push --app tymeslot.yourdomain.com ./my-env /app/data/.env

# Restart so the new values take effect
cloudron restart --app tymeslot.yourdomain.com
```

The file uses standard dotenv syntax: one `KEY=value` per line, `#` for comments. Quote any value that is not a plain word, and prefer single quotes: a single-quoted value is taken literally, character for character, so `SMTP_PASSWORD='p@ss #1 $x \ "q"'` means exactly what it says. Values containing a space, a `#`, a `$`, a quote or a backslash all need quoting. Double quotes work too but are not literal: they resolve escapes (`\n`, `\t`, `\uXXXX`) and expand `${VAR}` and `$(command)`, so inside them a literal `$` must be written `\$`, a `"` as `\"` and a backslash as `\\`. Use them for a value that contains a single quote, which is the one thing single quotes cannot hold: dotenv has no escape for it. Unquoted values are the case to avoid, because the two readers of this file (the container, at boot, and the release itself, in `cloudron exec` sessions) do not agree on them: `KEY=p#ss` is read as `p#ss` by one and `p` by the other, and `KEY=C:\path` keeps the backslash in one and drops it in the other. Quoted, both read the same value. The `--import` command below already writes values in this form, so anything it copies for you is correct as it stands.

The file must live in `/app/data`: `/app` itself is read-only on Cloudron and is replaced on every app upgrade, which is also why upgrades never touch your file. The reference copy that seeded it stays at `/app/.env.example` and is refreshed with each release, so `diff` it against your own file after an upgrade to see what is new.

Variables set with `cloudron env set` always win over `.env` entries, so use the CLI for one-off overrides. `SECRET_KEY_BASE` and `DATA_ENCRYPTION_KEY` are honoured from the file too, and setting either there stops the container generating its own; leave them alone unless you are restoring an existing installation.

### Moving Existing Variables Into the File

Copying a variable into the file does not move it: Cloudron still supplies it and still wins, so editing it in the file changes nothing until you take it out of Cloudron. The order matters, and this order is safe at every step, because the value is in both places until the last command.

1. Check what the file already holds. If the app was seeded as described above, your variables are in there already and you can skip to step 3.

   ```bash
   cloudron exec --app tymeslot.yourdomain.com -- grep -v '^#' /app/data/.env
   ```

2. If your file predates seeding, the container writes the current values for you. The boot log names this command whenever there is something to copy. It appends, never overwrites, and naming the file twice is deliberate: the first is read to skip variables it already assigns, so running it again adds nothing and cannot leave two lines for one variable.

   ```bash
   cloudron exec --app tymeslot.yourdomain.com -- sh -c '/app/env-template.sh --import /app/data/.env >> /app/data/.env'
   ```

   To get the commented reference list as well, run the same command with `--template` instead of `--import`.

3. Compare the two lists and confirm every variable you set is present in the file.

   ```bash
   cloudron env list --app tymeslot.yourdomain.com
   ```

   Anything the import skipped, and anything Cloudron sets that Tymeslot does not document, must be copied by hand before the next step. The import deliberately leaves the platform's own variables (`CLOUDRON_*`, `PORT`, `DEPLOYMENT_TYPE` and friends) alone: those belong to Cloudron, and pinning addon credentials in a file would break them the moment Cloudron rotates one.

4. Hand the variables over, naming the ones you copied. The app restarts and picks the values up from the file.

   ```bash
   cloudron env unset --app tymeslot.yourdomain.com PHX_HOST EMAIL_ADAPTER SMTP_HOST
   ```

The boot log after seeding prints this command with your own variables already filled in. To go back, `cloudron env set` the variable again: it takes precedence over the file immediately.

### Accessing Your Installation

Once deployed, Tymeslot will be available at:
- **URL**: `https://tymeslot.yourdomain.com` (or your configured subdomain)
- **SSL**: Automatically configured by Cloudron

### Becoming an admin

The first user to register on a fresh install is automatically promoted to admin. To promote additional users, open the app's Terminal from the Cloudron dashboard and run:

```bash
bin/tymeslot rpc 'Tymeslot.Release.promote_admin("you@example.com")'
```

Or from your workstation with the Cloudron CLI:

```bash
cloudron exec --app tymeslot.yourdomain.com -- bin/tymeslot rpc 'Tymeslot.Release.promote_admin("you@example.com")'
```

See [`docs/ADMIN.md`](docs/ADMIN.md) for the full guide (demote, list, recovery paths).

---

## Configuration

### Environment Variables

Cloudron automatically provides these variables:
- `CLOUDRON_POSTGRESQL_*` — Database connection details
- `CLOUDRON_MAIL_*` — Sendmail addon (email relay, auto-detected)
- `CLOUDRON_OIDC_*` — OIDC addon (SSO, auto-detected)
- `DEPLOYMENT_TYPE=cloudron` — Set automatically

### Data-at-rest encryption

Integration credentials are encrypted at rest with AES-256-GCM. On first boot the container
automatically generates a dedicated `DATA_ENCRYPTION_KEY` and persists it to
`/app/data/data_encryption_key` (included in Cloudron backups). This decouples data-at-rest
encryption from `SECRET_KEY_BASE`, so the session secret can be rotated without making stored
credentials undecryptable. No action is required for new installs.

**Upgrading an existing install:** the key is generated on the first boot after the upgrade.
New credentials are written under it immediately; existing credentials keep decrypting under
the old (`SECRET_KEY_BASE`-derived) key automatically. To migrate the existing rows onto the
new key, run the re-encryption sweep once. `cloudron exec` starts a fresh session that does
not see the key unless it is read from the file it was generated into, so export it first:

```bash
cloudron exec --app tymeslot.yourdomain.com -- sh -c '
  export DATA_ENCRYPTION_KEY=$(cat /app/data/data_encryption_key)
  /app/bin/tymeslot eval "Ecto.Migrator.with_repo(Tymeslot.Repo, fn _ -> IO.inspect(Tymeslot.Security.CredentialReencryption.run(), label: \"reencryption\") end)"
'
```

Re-run until the reported `migrated_values` is `0`. The sweep is idempotent and safe to
repeat. Do not delete `/app/data/data_encryption_key` — losing it makes stored credentials
unrecoverable.

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

**Option A: a provider API**
```bash
cloudron env set --app tymeslot.yourdomain.com EMAIL_ADAPTER=postmark EMAIL_FROM_NAME=Tymeslot EMAIL_FROM_ADDRESS=noreply@yourdomain.com POSTMARK_API_KEY=your_postmark_api_key
```

The other supported API providers take the same shape, with their own variables:

| `EMAIL_ADAPTER` | Additional variables |
|---|---|
| `postmark` | `POSTMARK_API_KEY` |
| `sendgrid` | `SENDGRID_API_KEY` |
| `mailgun` | `MAILGUN_API_KEY`, `MAILGUN_DOMAIN`, optional `MAILGUN_BASE_URL` for EU accounts |
| `ahasend` | `AHASEND_API_KEY`, `AHASEND_ACCOUNT_ID` |

**Option B: SMTP**
```bash
cloudron env set --app tymeslot.yourdomain.com EMAIL_ADAPTER=smtp EMAIL_FROM_NAME=Tymeslot EMAIL_FROM_ADDRESS=noreply@yourdomain.com SMTP_HOST=your_smtp_host SMTP_PORT=587 SMTP_USERNAME=your_smtp_username SMTP_PASSWORD=your_smtp_password
```

Any provider without an entry above works over SMTP. An `EMAIL_ADAPTER` value Tymeslot does not recognise stops the app at boot rather than discarding mail silently, so a typo here surfaces immediately in `cloudron logs`.

Ports 587 (STARTTLS) and 465 (implicit TLS) are both supported, and the relay's certificate is verified against the system trust store. Pointing `SMTP_HOST` at your own mail server usually needs one more variable, because a self-hosted relay commonly serves a self-signed certificate: set `SMTP_CACERTFILE` to a PEM bundle containing the CA that issued it, or, as a last resort where there is no CA to trust, `SMTP_TLS_VERIFY=none` to accept any certificate. The second still encrypts the connection but stops checking the relay's identity.


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

### Community Package (Option A)

Cloudron checks for new versions automatically. When a new release is published, you'll see an update prompt in the dashboard — apply it with one click or via CLI:

```bash
cloudron update --app tymeslot.yourdomain.com
```

### Manual Docker Build (Option B)

Rebuild the image from the latest source and push it to your registry, then update:

```bash
docker build -t your-registry/tymeslot-cloudron:latest .
docker push your-registry/tymeslot-cloudron:latest
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
- **Memory**: Minimum 500MB, recommended 1GB
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
