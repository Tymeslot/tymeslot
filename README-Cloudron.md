# Tymeslot - Cloudron Deployment Guide

![Tymeslot Logo](https://via.placeholder.com/200x80/4F46E5/FFFFFF?text=Tymeslot)

**Enterprise-grade meeting scheduling with multi-provider calendar and video conferencing integration**

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

### 1. Install via Cloudron App Store

```bash
# Option 1: Install from Cloudron App Store (if published)
# Search for "Tymeslot" in your Cloudron dashboard

# Option 2: Install from source
git clone https://github.com/yourusername/tymeslot.git
cd tymeslot
```

### 2. Build and Install

```bash
# Build the Cloudron package
docker build -t tymeslot:cloudron .

# Install via Cloudron CLI
cloudron install --image tymeslot:cloudron --location tymeslot.yourdomain.com
```

### 3. Access Your Installation

Once deployed, Tymeslot will be available at:
- **URL**: `https://tymeslot.yourdomain.com` (or your configured subdomain)
- **SSL**: Automatically configured by Cloudron

---

## Configuration

### Environment Variables

Cloudron automatically provides these variables:
- `CLOUDRON_POSTGRESQL_*` - Database connection details
- `DEPLOYMENT_TYPE=cloudron` - Set automatically

### Required Configuration

You need to configure these via Cloudron's environment variable interface:

#### 1. Application Settings
```bash
SECRET_KEY_BASE=your_secret_key_here  # Generate with: openssl rand -base64 64
PHX_HOST=tymeslot.yourdomain.com      # Your Cloudron domain
PORT=4000                             # Default port (managed by Cloudron)
LIVE_VIEW_SIGNING_SALT=your_live_view_salt  # Generate with: openssl rand -base64 32
```

#### 2. OAuth Providers (Optional)

**GitHub OAuth:**
```bash
GITHUB_CLIENT_ID=your_github_client_id
GITHUB_CLIENT_SECRET=your_github_client_secret
```

**Google OAuth:**
```bash
GOOGLE_CLIENT_ID=your_google_client_id
GOOGLE_CLIENT_SECRET=your_google_client_secret
GOOGLE_STATE_SECRET=random_secret_string
```

**Microsoft OAuth:**
```bash
OUTLOOK_CLIENT_ID=your_outlook_client_id
OUTLOOK_CLIENT_SECRET=your_outlook_client_secret
OUTLOOK_STATE_SECRET=random_secret_string
```

#### 3. Email Configuration

**Option A: Postmark (Recommended)**
```bash
EMAIL_ADAPTER=postmark
EMAIL_FROM_NAME=Tymeslot
EMAIL_FROM_ADDRESS=noreply@yourdomain.com
POSTMARK_API_KEY=your_postmark_api_key
```

**Option B: SMTP**
```bash
EMAIL_ADAPTER=smtp
EMAIL_FROM_NAME=Tymeslot
EMAIL_FROM_ADDRESS=noreply@yourdomain.com
SMTP_HOST=your_smtp_host
SMTP_PORT=587
SMTP_USERNAME=your_smtp_username
SMTP_PASSWORD=your_smtp_password
```


---

## Setting Environment Variables in Cloudron

1. **Access App Settings**
   - Go to your Cloudron dashboard
   - Navigate to **Apps** → **Tymeslot**
   - Click **Configure**

2. **Environment Variables**
   - Go to **Environment** tab
   - Add each variable using the format: `VARIABLE_NAME=value`
   - Click **Save**

3. **Restart App**
   - Click **Restart** to apply changes

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

### Automatic Updates
```bash
# Update via Cloudron CLI
cloudron update --app tymeslot.yourdomain.com

# Or use Cloudron dashboard
# Apps → Tymeslot → Update
```

### Manual Updates
```bash
# Pull latest code
git pull origin main

# Rebuild image
docker build -t tymeslot:cloudron .

# Update installation
cloudron install --image tymeslot:cloudron --app tymeslot.yourdomain.com
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

---

**Congratulations!** 🎉 Tymeslot is now running on Cloudron with enterprise-grade reliability and security.
