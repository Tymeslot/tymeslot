# Tymeslot

**Enterprise-grade meeting scheduling platform built with Elixir/Phoenix LiveView**

Tymeslot provides comprehensive appointment booking with multi-provider calendar and video conferencing integration. It combines advanced user management, flexible calendar synchronization, professional email notifications, and multi-provider video conferencing into a seamless, customizable scheduling experience.

[![License: Elastic-2.0](https://img.shields.io/badge/License-Elastic--2.0-blue.svg)](https://www.elastic.co/licensing/elastic-license)
[![Elixir](https://img.shields.io/badge/Elixir-1.19.3-purple.svg)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.7-orange.svg)](https://phoenixframework.org)
[![Phoenix LiveView](https://img.shields.io/badge/Phoenix%20LiveView-1.0-red.svg)](https://github.com/phoenixframework/phoenix_live_view)

## ✨ Features

### 🔐 Comprehensive User Management
- **Multi-Provider Authentication**: OAuth (Google, GitHub), email/password with verification
- **User Profiles**: Customizable settings, avatars, timezone configuration
- **Onboarding Flow**: 4-step guided setup for new users
- **Dashboard**: Complete management interface with integrations and settings

### 🧠 Smart Scheduling Engine
- **Timezone Intelligence**: 90+ supported cities with automatic detection
- **Advanced Availability**: Custom business hours, breaks, overrides, and buffer times
- **Real-time Conflict Detection**: Parallel calendar fetching across multiple providers
- **Configurable Meeting Types**: Custom durations, video options, and branding

### 📅 Multi-Provider Calendar Integration
- **4 Calendar Providers**: Google Calendar, Outlook, CalDAV, Nextcloud
- **Full CRUD Operations**: Create, read, update, delete events across all providers
- **OAuth Management**: Automatic token refresh with secure credential storage
- **Calendar Discovery**: Auto-detection of available calendars per provider

### 🎥 Multi-Provider Video Conferencing
- **4 Video Providers**: MiroTalk P2P, Google Meet, Teams, Custom Links
- **Automatic Room Creation**: Provider-specific meeting generation
- **Role-based Access**: Separate URLs and permissions for organizers vs attendees
- **OAuth Integration**: Seamless setup with Google Meet and Teams

### 📧 Professional Email System
- **5 Email Types**: Confirmations, reminders, rescheduling, cancellations, error notifications
- **MJML Templates**: Responsive design with calendar attachments
- **Multi-Format Support**: Google Calendar, Outlook, and .ics downloads
- **Delivery Tracking**: Email status monitoring and retry logic

### 🔒 Advanced Security & Performance
- **Comprehensive Rate Limiting**: IP-based protection with progressive delays
- **Input Sanitization**: XSS protection and form validation across all inputs
- **Security Headers**: CSP, HSTS, frame protection, and CSRF tokens
- **Data Encryption**: AES encryption for API keys and sensitive credentials
- **Circuit Breakers**: Resilient external service integration with graceful degradation
- **reCAPTCHA v3 Bot Protection**: Optional bot detection for signup (configurable, auto-disables if keys missing)

## 🚀 Quick Start

### Prerequisites
- Elixir 1.19.3+ and Erlang 28.1.1+
- PostgreSQL 14+
- Node.js 18+ (for asset compilation)

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/your-username/tymeslot.git
   cd tymeslot
   ```

2. **Install dependencies**
   ```bash
   mix deps.get
   cd assets && npm install && cd ..
   ```

3. **Set up environment variables**
   ```bash
   cp .env.example .env
   # Edit .env with your configuration
   ```

4. **Create and migrate database**
   ```bash
   mix ecto.create
   mix ecto.migrate
   ```

5. **Start the development server**
   ```bash
   mix phx.server
   ```

Visit [`localhost:4000`](http://localhost:4000) to see the application.

## 🐳 Docker Deployment

### Quick Start with Docker
```bash
# Build and run
docker build -f Dockerfile.docker -t tymeslot .
docker run -p 4000:4000 --env-file .env tymeslot
```

### Docker Compose (Recommended)
```yaml
version: '3.8'
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.docker
    ports:
      - "4000:4000"
    environment:
      - DATABASE_URL=postgresql://postgres:password@db:5432/tymeslot
      - SECRET_KEY_BASE=your_secret_key_here
    depends_on:
      - db
  
  db:
    image: postgres:15
    environment:
      - POSTGRES_DB=tymeslot
      - POSTGRES_PASSWORD=password
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
```

## ☁️ Cloudron Deployment

Tymeslot includes native Cloudron support for easy self-hosted deployment:

1. Install from the Cloudron App Store (coming soon)
2. Or use the manifest: `CloudronManifest.json`

See [README-Cloudron.md](README-Cloudron.md) for detailed instructions.

## ⚙️ Configuration

### Required Environment Variables

```bash
# Application
SECRET_KEY_BASE=your_secret_key_here
PHX_HOST=your.domain.com
PORT=4000

# Database
DATABASE_URL=postgresql://user:pass@host/db
DATABASE_POOL_SIZE=100

# OAuth Providers
GOOGLE_CLIENT_ID=your_google_client_id
GOOGLE_CLIENT_SECRET=your_google_client_secret
GITHUB_CLIENT_ID=your_github_client_id
GITHUB_CLIENT_SECRET=your_github_client_secret

# Email (Postmark recommended)
EMAIL_ADAPTER=postmark
EMAIL_FROM_NAME="Your App Name"
EMAIL_FROM_ADDRESS=hello@yourdomain.com
POSTMARK_API_KEY=your_postmark_key

# reCAPTCHA (Optional, for signup bot protection)
RECAPTCHA_SITE_KEY=your_recaptcha_v3_site_key
RECAPTCHA_SECRET_KEY=your_recaptcha_v3_secret_key
RECAPTCHA_SIGNUP_ENABLED=true  # Set to 'true' to enable signup verification
RECAPTCHA_SIGNUP_MIN_SCORE=0.3  # Score threshold (0.0-1.0); default 0.3
```

See `.env.example` for the complete configuration template.

### reCAPTCHA Setup (Optional)

Tymeslot includes optional **reCAPTCHA v3 bot protection** for user signups.

1. **Create a reCAPTCHA v3 key** at [Google reCAPTCHA Admin](https://www.google.com/recaptcha/admin)
2. **Set environment variables**:
   ```bash
   RECAPTCHA_SITE_KEY=your_site_key
   RECAPTCHA_SECRET_KEY=your_secret_key
   RECAPTCHA_SIGNUP_ENABLED=true
   RECAPTCHA_SIGNUP_MIN_SCORE=0.3  # Default: 0.3 (permissive); adjust 0.0–1.0
   ```
3. **Restart the application**

**Details**: See code comments for tuning strategy and monitoring.


### OAuth Setup

1. **Google OAuth**: Create credentials at [Google Cloud Console](https://console.cloud.google.com/)
2. **GitHub OAuth**: Create an OAuth App at [GitHub Settings](https://github.com/settings/developers)
3. **Microsoft OAuth**: Register at [Azure App Registration](https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)

## 🏗️ Architecture

Tymeslot follows **domain-driven design** with clear bounded contexts:

### Core Domains
- **Authentication Domain**: Multi-provider OAuth, email verification, session management
- **User Profiles Domain**: Settings, preferences, avatar management, onboarding
- **Availability Domain**: Business hours, breaks, overrides, timezone calculations
- **Bookings Domain**: Meeting lifecycle with orchestrator pattern
- **Integrations Domain**: Multi-provider calendar and video with registry pattern
- **Notifications Domain**: Event-driven email system with scheduling
- **Security Domain**: Rate limiting, encryption, validation, account protection

### Key Patterns
- **Repository Pattern**: Clean data access with dedicated query modules
- **Circuit Breaker Pattern**: Resilient external service integration
- **Provider Pattern**: Extensible integration system with registries
- **Orchestrator Pattern**: Complex workflow coordination

## 🧪 Testing

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run integration tests (requires OAuth setup)
mix test --include integration_test

# Run specific test suites
mix test test/tymeslot/auth/
mix test test/tymeslot_web/live/
```

### Test Coverage
- Current: 11.17% (improving)
- Target: 75%
- Excludes: Integration tests, OAuth flows, external APIs

## 🎨 Themes

Tymeslot includes a flexible theme system:

- **Quill Theme**: Modern glassmorphism design
- **Rhythm Theme**: Sliding interface with animations

Themes are fully isolated with consistent functionality across all variations.

## 🤝 Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Development Setup

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Make your changes and add tests
4. Run the test suite: `mix test`
5. Run code quality checks: `mix credo` and `mix dialyzer`
6. Commit your changes: `git commit -m 'Add amazing feature'`
7. Push to your branch: `git push origin feature/amazing-feature`
8. Open a Pull Request

### Code Style
- Follow existing Elixir conventions
- Use `mix format` for code formatting
- Add tests for new functionality
- Update documentation as needed

## 📚 Documentation

- [Cloudron Deployment](README-Cloudron.md)
- [Docker Deployment](README-Docker.md)
- [Theme Development Guide](docs/THEME_DEVELOPMENT_GUIDE.md)
- [Design Language](DESIGN_LANGUAGE.md)
- [Debug Routes](DEBUG_ROUTES.md)

## 🛡️ Security

Tymeslot takes security seriously:

- All user inputs are sanitized and validated
- OAuth credentials are encrypted at rest
- Rate limiting prevents abuse
- Security headers protect against common attacks
- Regular dependency updates

To report security vulnerabilities, please email: security@tymeslot.app

## 📄 License

This project is licensed under the Elastic License 2.0 - see the [LICENSE](LICENSE) file for details.

## 🏢 About

Tymeslot is developed by:
- **Luka Karsten Breitig**
- **Diletta Luna OÜ**
- Sepapaja 6, 15551 Tallinn, Estonia

## 🌟 Support

- ⭐ Star this repository if you find it helpful
- 🐛 [Report bugs](https://github.com/your-username/tymeslot/issues)
- 💡 [Request features](https://github.com/your-username/tymeslot/issues)
- 📧 Contact: hello@tymeslot.app

---

**Built with ❤️ using Elixir, Phoenix, and LiveView**
