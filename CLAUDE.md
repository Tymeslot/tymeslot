# Tymeslot - Project Overview

## What This Project Does

**Tymeslot** is an enterprise-grade meeting scheduling platform built with Elixir/Phoenix LiveView that provides comprehensive appointment booking with multi-provider calendar and video conferencing integration. It combines advanced user management, flexible calendar synchronization (Google, Outlook, CalDAV), professional email notifications, and multi-provider video conferencing into a seamless, customizable scheduling experience.

## Technology Stack

### Core Framework
- **Elixir 1.19.3 / Erlang 28.1.1**: Fault-tolerant, concurrent runtime
- **Phoenix 1.7**: Modern web framework with excellent performance
- **Phoenix LiveView 1.0**: Real-time UI with minimal JavaScript
- **Ecto SQL**: Database wrapper with PostgreSQL adapter

### Key Dependencies & Integrations
- **Multi-Calendar Integration**: Google Calendar, Outlook, CalDAV, Nextcloud
- **Multi-Video Integration**: MiroTalk P2P, Google Meet, Teams, Custom Links
- **Authentication**: OAuth 2.0 (Google, GitHub), email/password with verification
- **Email**: Swoosh with MJML responsive templates and calendar attachments
- **Background Jobs**: Oban for async processing and scheduled tasks
- **Security**: Hammer (rate limiting), encryption, input sanitization
- **Frontend**: Tailwind CSS, ESBuild, themed UI components with video backgrounds
- **Infrastructure**: Circuit breakers, connection pooling, structured logging
- **Video System**: Multi-quality video backgrounds with crossfade capabilities

### Deployment Infrastructure
- **Main Cloud**: Managed cloud platform deployment for SaaS offering
- **Cloudron Platform**: Managed self-hosting with automatic SSL
- **Docker**: Containerized deployment for self-hosting
- **PostgreSQL**: Database with 100 connection pool and comprehensive indexing

## Core Features

### Comprehensive User Management
- **Multi-Provider Authentication**: OAuth (Google, GitHub), email/password with verification
- **User Profiles**: Customizable settings, avatars, timezone configuration
- **Onboarding Flow**: 4-step guided setup for new users
- **Dashboard**: Complete management interface with integrations and settings

### Smart Scheduling Engine
- **Timezone Intelligence**: 90+ supported cities with automatic detection
- **Advanced Availability**: Custom business hours, breaks, overrides, and buffer times
- **Real-time Conflict Detection**: Parallel calendar fetching across multiple providers
- **Configurable Meeting Types**: Custom durations, video options, and branding

### Multi-Provider Calendar Integration
- **4 Calendar Providers**: Google Calendar, Outlook, CalDAV, Nextcloud
- **Full CRUD Operations**: Create, read, update, delete events across all providers
- **OAuth Management**: Automatic token refresh with secure credential storage
- **Calendar Discovery**: Auto-detection of available calendars per provider

### Multi-Provider Video Conferencing
- **4 Video Providers**: MiroTalk P2P, Google Meet, Teams, Custom Links
- **Automatic Room Creation**: Provider-specific meeting generation
- **Role-based Access**: Separate URLs and permissions for organizers vs attendees
- **OAuth Integration**: Seamless setup with Google Meet and Teams

### Professional Email System
- **5 Email Types**: Confirmations, reminders, rescheduling, cancellations, error notifications
- **MJML Templates**: Responsive design with calendar attachments
- **Multi-Format Support**: Google Calendar, Outlook, and .ics downloads
- **Delivery Tracking**: Email status monitoring and retry logic

### Advanced Security & Performance
- **Comprehensive Rate Limiting**: IP-based protection with progressive delays
- **Input Sanitization**: XSS protection and form validation across all inputs
- **Security Headers**: CSP, HSTS, frame protection, and CSRF tokens
- **Data Encryption**: AES encryption for API keys and sensitive credentials
- **Circuit Breakers**: Resilient external service integration with graceful degradation

## Architecture Overview

The application follows **domain-driven design** with clear bounded contexts and enterprise-grade patterns:

### Core Domains
- **Authentication Domain**: Multi-provider OAuth, email verification, session management
- **User Profiles Domain**: Settings, preferences, avatar management, onboarding
- **Availability Domain**: Business hours, breaks, overrides, timezone calculations
- **Bookings Domain**: Meeting lifecycle with orchestrator pattern
- **Integrations Domain**: Multi-provider calendar and video with registry pattern
- **Notifications Domain**: Event-driven email system with scheduling
- **Security Domain**: Rate limiting, encryption, validation, account protection

### Infrastructure Layer
- **Repository Pattern**: Clean data access with dedicated query modules
- **Circuit Breaker Pattern**: Resilient external service integration
- **Provider Pattern**: Extensible integration system with registries
- **Orchestrator Pattern**: Complex workflow coordination
- **Background Jobs**: Oban-powered async processing with retry logic

### Key Business Logic

**Availability Calculation**: Combines configurable business hours with calendar conflicts across multiple providers, handling timezone conversions, DST transitions, breaks, and overrides.

**User Onboarding**: 4-step guided setup including profile creation, preferences configuration, and integration setup with skip options.

**Booking Flow** (2 Theme Options):
1. **Overview**: Meeting type and duration selection with user branding
2. **Calendar**: Interactive month/week view with real-time availability
3. **Booking Form**: Contact details, company info, and meeting description
4. **Confirmation**: Success page with multi-format calendar downloads and video links

**Meeting Management**: Complete lifecycle with secure token-based rescheduling, one-click cancellation, automated reminders, and email notifications.

## User Experience

### Authentication & Registration
- **Multi-provider signup**: Email/password, Google OAuth, GitHub OAuth
- **Email verification**: Required for email/password accounts
- **Password security**: Strong validation with secure hashing
- **Account recovery**: Secure password reset flow

### Primary User Journey
1. **Homepage** (`/`) - Marketing page with feature overview and signup CTA
2. **Registration/Login** - Multi-provider authentication with guided onboarding
3. **Dashboard Setup** - Profile, integrations, and scheduling preferences
4. **Public Scheduling Page** (`/:username`) - Personalized booking interface
5. **Meeting Management** - Lifecycle management with notifications

### Dashboard Features (8 Sections)
- **Overview**: Stats, upcoming meetings, quick actions
- **Profile Settings**: Name, username, timezone, avatar management
- **Availability**: Business hours, breaks, overrides, buffer times
- **Meeting Types**: Custom durations, video options, icons
- **Calendar Integration**: Multi-provider setup with OAuth flows
- **Video Integration**: 5 providers with connection testing
- **Meetings**: Lifecycle management and history
- **Account Security**: Password changes, email updates

### Theme System
- **2 Available Themes**: Quill (glassmorphism), Rhythm (modern sliding with video backgrounds)
- **Dynamic Routing**: Theme-specific components and flows
- **Consistent Functionality**: Same features across all themes
- **Advanced Customization**: Video backgrounds, image backgrounds, gradient backgrounds
- **Performance Optimization**: Connection-aware video loading, battery-conscious playback
- **Accessibility**: Reduced motion support, data-saver friendly

## Configuration

### Environment Variables
- **Database**: PostgreSQL connection configuration (deployment-specific)
- **Deployment**: DEPLOYMENT_TYPE environment variable (main/cloudron/docker)
- **Application**: Phoenix secret key, hostname, and port configuration
- **Email**: Swoosh/SMTP configuration for transactional emails
- **OAuth**: Client IDs/secrets for Google and GitHub integration
- **Development**: Debug flags, theme selection, and testing modes

### User Settings (Database-Backed)
Comprehensive user preferences with dashboard management:
- **Profile**: Full name, username, timezone, avatar
- **Availability**: Business hours, breaks, overrides
- **Scheduling**: Buffer time (0-120 min), booking window (1-365 days), minimum notice (0-168 hrs)
- **Meeting Types**: Custom durations, video options, icons
- **Integrations**: Calendar and video provider credentials (encrypted)
- **Themes**: Preferred booking interface theme with advanced customization
- **Theme Customization**: Background type (gradient/color/image/video), custom colors, uploaded assets

## Development & Testing

### Code Style Guidelines
- **Module Aliases**: Always alias modules at the top of files in proper alphabetical order
  - Never use nested aliases within functions or code blocks
  - Keep all aliases grouped at the module level for clarity and consistency
- **Avoid Thin Wrapper Functions**: Do not create private functions that simply wrap already-aliased module calls
  - Instead of `defp format_name(x), do: ModuleName.format_name(x)`, call `ModuleName.format_name(x)` directly
  - Thin wrappers add unnecessary indirection and make code less transparent
  - Use direct module calls with proper aliases for clarity and maintainability
- **Phoenix LiveView Components**: Stateful components must have a single static HTML tag at the root
  - Never wrap stateful component render functions in multiple root elements
  - Use a single `<div>` or other HTML element to wrap all content in stateful components

### Code Organization Principles
- **Functional-First Design**: Favor pure functions, immutable data structures, and function composition over stateful objects
- **Domain-Driven Structure**: Organize modules around business domains, not technical layers
- **Clear Bounded Contexts**: Each domain should have well-defined responsibilities and minimal cross-domain coupling
- **Business Logic Isolation**: Keep domain logic separate from infrastructure concerns (web, database, external APIs)
- **Functional Core, Imperative Shell**: Pure business logic at the core, side effects at the boundaries

### UI/CSS Design System Guidelines
- **Use Established Design System**: The app has a comprehensive CSS design system in `assets/css/` with consistent styling patterns
  - **Design Tokens**: Use CSS custom properties from `assets/css/base/variables.css` (colors, spacing, typography, shadows, etc.)
  - **Component Classes**: Use pre-built component classes from `assets/css/components/` (buttons, forms, cards, etc.)
  - **Glass Morphism Theme**: Consistent glassmorphism styling with turquoise primary colors and backdrop blur effects
- **Component Structure**: Use existing UI components from `lib/tymeslot_web/components/core_components.ex` for layouts, buttons, forms
- **CSS Architecture**: Follow the modular CSS structure - avoid inline Tailwind when component classes exist
- **Theme Consistency**: Maintain the established glassmorphism aesthetic with proper blur effects, transparency, and color schemes

### Git Commit Guidelines
- **Commit Messages**: Do not include Claude Code signature in commit messages
  - Avoid: `🤖 Generated with [Claude Code](https://claude.ai/code)`
  - Avoid: `Co-Authored-By: Claude <noreply@anthropic.com>`
  - Keep commit messages focused on technical changes and business value

### Test Infrastructure
- **ExUnit**: Async test framework with 75% coverage threshold
- **Mox**: Behavior-based mocking for external integrations
- **Ex Machina**: Factory-based test data generation
- **Integration Tests**: Complete user journey and provider testing
- **Unit Tests**: Comprehensive domain logic and edge case coverage
- **Debug Scripts**: 50+ utility scripts for troubleshooting integrations

### Development Tools
- **Phoenix Dev Server**: Live reloading with Tailwind/ESBuild watchers
- **Swoosh Mailbox**: Email preview at `/dev/mailbox` with MJML rendering
- **IEx Console**: Interactive debugging with complete application context
- **Theme Development**: Debug routes for theme testing and validation
- **Dialyzer**: Static analysis with comprehensive PLT management
- **Credo**: Code quality analysis and style enforcement

## Recent Major Updates

### Complete Authentication & User Management System
- Multi-provider OAuth integration (Google, GitHub)
- Email verification and password reset flows
- User profiles with avatar management and customizable settings
- 4-step onboarding process with dashboard interface

### Multi-Provider Integration Architecture
- **Calendar Integration**: 4 providers (Google, Outlook, CalDAV, Nextcloud)
- **Video Integration**: 4 providers (MiroTalk, Google Meet, Teams, Custom)
- Provider registry pattern with OAuth flows and credential encryption
- Automated token refresh and connection health monitoring

### Advanced Video Background System
- **Multi-Quality Video Assets**: Desktop WebM/MP4, mobile MP4, low-bandwidth variants
- **Crossfade Technology**: Seamless video transitions for premium themes
- **Performance Optimization**: Connection-aware loading, battery-conscious playback
- **Accessibility Features**: Reduced motion support, data-saver compatibility
- **Video Infrastructure**: Video helpers, asset management, responsive rendering

### Enhanced Theme Architecture
- 2 complete themes (Quill, Rhythm) with video background support
- Advanced theme customization with video/image/gradient backgrounds
- New architecture components: capability customizer, error boundary, event bus
- Theme loader system with dynamic registration and enhanced asset management
- Improved theme dispatcher with better state management

### Source-Available Licensing & Documentation
- **Elastic License 2.0**: Source-available license that permits self-hosting and modifications while preventing third-party hosted service offerings
- **Comprehensive README**: 287-line professional documentation with setup guides
- **Contribution Guidelines**: 435-line CONTRIBUTING.md with development standards
- **Ready for Community**: Complete documentation for community contribution and self-hosting

### Enterprise-Grade Security & Infrastructure
- Circuit breaker pattern for external service resilience
- Comprehensive rate limiting with progressive delays
- AES encryption for sensitive credentials
- Background job processing with Oban for scalability

## Conclusion

Tymeslot is an enterprise-grade scheduling platform that demonstrates mature software architecture and comprehensive feature development. Built with Elixir's fault-tolerant foundation, it provides a complete solution for professional appointment scheduling with multi-provider integrations, advanced user management, and extensive security features. The platform successfully combines technical excellence with exceptional user experience, offering both flexibility for developers and simplicity for end users.
