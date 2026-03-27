<div align="center">

<img src="./priv/static/images/brand/logo-with-text.svg" alt="Tymeslot" height="80" />

**Open-source appointment scheduling. Self-host in minutes.**

Booking pages, calendar sync, video rooms, and automated emails — on your server. Built on Elixir/OTP so it keeps running while you're not looking.

[![License: Elastic-2.0](https://img.shields.io/badge/License-Elastic--2.0-blue.svg)](https://www.elastic.co/licensing/elastic-license)
[![Elixir](https://img.shields.io/badge/Elixir-1.19.3-purple.svg)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8-orange.svg)](https://phoenixframework.org)
[![Phoenix LiveView](https://img.shields.io/badge/LiveView-1.1-red.svg)](https://github.com/phoenixframework/phoenix_live_view)
[![GitHub stars](https://img.shields.io/github/stars/tymeslot/tymeslot?style=social)](https://github.com/tymeslot/tymeslot/stargazers)

[**Deploy with Docker →**](README-Docker.md) · [**Try Cloud →**](https://tymeslot.app)<br>
[**Docs →**](https://tymeslot.app/docs) · [**Issues →**](https://github.com/tymeslot/tymeslot/issues)

</div>

---

Tymeslot is a scheduling platform you deploy yourself. Connect your calendars, set your hours, share a booking link — and it handles the rest: video rooms generated at booking time, confirmation emails with `.ics` attachments, configurable reminders, reschedule and cancel flows, and webhook notifications when anything changes.

Single Docker container. PostgreSQL included. Built on Elixir/OTP — designed to run unattended without falling over.

No tracking pixels. No analytics pipeline. No data leaving your server.

> Evaluating alternatives? [See how Tymeslot compares to Calendly.](#tymeslot-vs-calendly)

---

## Quick Start

```bash
docker run --name tymeslot \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')" \
  -e PHX_HOST=localhost \
  -v tymeslot_data:/app/data \
  -v tymeslot_pg:/var/lib/postgresql/data \
  youruser/tymeslot:latest
```

Open [http://localhost:4000](http://localhost:4000) — your scheduling platform is running. For SMTP, TLS, and reverse proxy setup, see the [Docker guide](README-Docker.md).

---

## Features

### Scheduling

- **No double-bookings** — every connected calendar is checked at the moment of booking, not on a schedule; one conflict anywhere blocks the slot everywhere
- **Availability that reflects reality** — working hours per day, date-specific overrides for holidays, and vacation blocks without touching a calendar
- **Buffer time** — pad before, after, or both, per meeting type (0–120 min)
- **Booking window** — nobody schedules six months out without your permission (1–365 days)
- **Minimum notice** — enough lead time that you can actually prepare (0–168 hours)
- **Timezone-aware** — 90+ cities, DST handled correctly, browser-detected on the booking page

### Calendar Integrations

<div align="center">
  <img src="./priv/static/icons/providers/calendar/medium/google.png" alt="Google Calendar" height="48" title="Google Calendar" />
  <img src="./priv/static/icons/providers/calendar/medium/outlook.png" alt="Outlook Calendar" height="48" title="Outlook Calendar" />
  <img src="./priv/static/icons/providers/calendar/medium/caldav.png" alt="CalDAV" height="48" title="CalDAV" />
  <img src="./priv/static/icons/providers/calendar/medium/nextcloud.png" alt="Nextcloud" height="48" title="Nextcloud Calendar" />
  <img src="./priv/static/icons/providers/calendar/medium/radicale.png" alt="Radicale" height="48" title="Radicale" />
  <img src="./priv/static/icons/providers/calendar/medium/zimbra.png" alt="Zimbra" height="48" title="Zimbra" />
</div>

| Provider | Auth |
|----------|------|
| Google Calendar | OAuth 2.0 with automatic token refresh |
| Microsoft Outlook / 365 | OAuth 2.0 with automatic token refresh |
| CalDAV | Username / password |
| Nextcloud Calendar | CalDAV |
| Zimbra | CalDAV |
| Radicale | CalDAV |

Connect as many calendars as you have. Assign each meeting type to whichever calendar it belongs in. If an integration goes down, you get an email — you won't find out from a missed meeting.

### Video Conferencing

<div align="center">
  <img src="./priv/static/icons/providers/video/medium/google_meet.png" alt="Google Meet" height="48" title="Google Meet" />
  <img src="./priv/static/icons/providers/video/medium/teams.png" alt="Microsoft Teams" height="48" title="Microsoft Teams" />
  <img src="./priv/static/icons/providers/video/medium/mirotalk.png" alt="MiroTalk P2P" height="48" title="MiroTalk P2P" />
  <img src="./priv/static/icons/providers/video/medium/local.png" alt="In-Person / Phone" height="48" title="In-Person / Phone" />
  <img src="./priv/static/icons/providers/video/medium/custom.png" alt="Custom Links" height="48" title="Custom Video Links" />
</div>

| Provider | Notes |
|----------|-------|
| Google Meet | Auto-generated via OAuth |
| Microsoft Teams | Auto-generated via OAuth |
| MiroTalk P2P | Self-hosted open-source WebRTC |
| In-Person / Phone | Location/phone in email, no link |
| Custom link | Static or dynamic URL |

Each meeting type picks its own provider — a sales call can use Meet while an internal sync uses MiroTalk.

### Authentication

Works with whatever you already use for identity:

- Email/password with verification flow
- Google OAuth, GitHub OAuth
- Generic OAuth 2.0 / OIDC — Keycloak, Authentik, Okta, Azure AD, or any standards-compliant provider
- Registration and password auth can each be disabled independently — SSO-only and closed deployments are first-class. See [Configuration](#configuration).

### Notifications & Automation

**Email** — responsive MJML templates, `.ics` attachment on every outgoing email:
- Booking confirmation — organizer and attendee
- Reminders — configurable count and timing (minutes/hours/days before), per meeting type
- Cancellation and reschedule notices — both parties, via signed guest links
- Integration health alerts — you hear about a broken calendar before your bookers do

**Telegram** — booking, cancellation, and reschedule alerts to your phone. Use a shared bot or configure a personal one per user.

**Webhooks** — HMAC-signed HTTP POST on `meeting_created`, `meeting_cancelled`, and `meeting_rescheduled`. Plug it into n8n, Zapier, Make, or your own backend.

### Booking Lifecycle

- Attendees book without an account — name, email, timezone, optional message, done
- Every confirmation includes signed cancel and reschedule links — no login, no support ticket
- Attendees can propose a new time; the organizer gets notified and confirms
- Calendar events write on booking, update on reschedule, cancel on cancellation

### Embedding

Drop a `<script>` tag on any page and pick your embed style:

| Mode | Description |
|------|-------------|
| Inline | Renders the booking widget inline on the page |
| Popup modal | Full-screen overlay triggered by any element |
| Floating button | Fixed-position widget anchored to a corner |
| Direct link | Personal booking URL (`/:username/:meeting-type`) |

Embeds are signed (6-hour token expiry) and domain-locked — your widget, only on your site.

### Customization

- **Two themes** — Quill and Rhythm, both with dark mode
- **Accent color** — override the brand color to match your identity
- **Backgrounds** — solid, gradient, image, or video, with presets if you'd rather not choose
- **Four languages** — English, German, Ukrainian, French, browser-detected with manual override
- **White-label** — strip Tymeslot branding entirely (Pro, cloud only)

### Security

Security is structural here, not bolted on after the fact:

- OAuth tokens and API credentials are AES-encrypted at rest — they never appear in logs as plaintext
- Rate limiting on every public endpoint: booking, auth, and embed
- No third-party analytics, tracking pixels, or outbound data of any kind
- CSRF on all forms, HMAC signatures on webhook payloads, signed tokens on embeds and guest links
- Optional reCAPTCHA v3 and honeypot fields on all public forms — see [Configuration](#configuration)

---

## Screenshots

**Dashboard**

![Dashboard](./priv/static/images/screenshots/dashboard.png)

**Booking Page**

![Availability](./priv/static/images/screenshots/availability.png)

**Embed Widget**

![Embedding](./priv/static/images/screenshots/embedding.png)

---

## Deployment

| Method | Guide | Notes |
|--------|-------|-------|
| Docker | [README-Docker.md](README-Docker.md) | Recommended for most self-hosters |
| Cloudron | [README-Cloudron.md](README-Cloudron.md) | One-click install, automatic updates |
| Railway | [Deploy →](https://railway.com/deploy/tymeslot) | One-click, no server management |
| Cloud | [tymeslot.app](https://tymeslot.app) | Managed, zero setup |

---

## Configuration

Key environment variables for self-hosted deployments.

**Required:**

| Variable | Description |
|----------|-------------|
| `SECRET_KEY_BASE` | Generate with `openssl rand -base64 64` |
| `PHX_HOST` | Public hostname for URL generation |

**Access control:**

| Variable | Default | Description |
|----------|---------|-------------|
| `REGISTRATION_ENABLED` | `true` | Set `false` to close sign-ups |
| `PASSWORD_AUTH_ENABLED` | `true` | Set `false` for OAuth/SSO only |

**Spam protection (optional):**

| Variable | Default | Description |
|----------|---------|-------------|
| `RECAPTCHA_SITE_KEY` | — | Enables reCAPTCHA v3 |
| `RECAPTCHA_SECRET_KEY` | — | Pair with site key |
| `RECAPTCHA_SIGNUP_ENABLED` | `false` | reCAPTCHA on signup |
| `RECAPTCHA_BOOKING_ENABLED` | `false` | reCAPTCHA on booking |

For the full configuration reference (SMTP, database, OAuth provider credentials, etc.), see the [Docker guide](README-Docker.md).

### Disabling registration

Set `REGISTRATION_ENABLED=false` to close sign-ups without taking the app down — useful for invite-only or single-user deployments. When disabled, the sign-up page is hidden and OAuth registration is rejected; existing users continue to log in normally.

### SSO-only mode

Set `PASSWORD_AUTH_ENABLED=false` to hide the email/password form entirely and require OAuth or OIDC. Direct `POST /auth/session` requests are rejected with an error. Existing users with passwords can still sign in via OAuth if configured.

Report security vulnerabilities via the [contact page](https://tymeslot.app/contact).

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Elixir 1.19 / OTP 28 |
| Web | Phoenix 1.8 · Phoenix LiveView 1.1 |
| Database | PostgreSQL 14+ · Ecto SQL |
| Background jobs | Oban |
| Frontend | Tailwind CSS · Alpine.js · ESBuild |
| Email | Swoosh · MJML |
| Deployment | Docker · Cloudron |

---

## Tymeslot vs Calendly

| | Tymeslot | Calendly |
|--|----------|----------|
| Open source | ✅ ELv2 | ❌ |
| Self-hosting | ✅ Free forever | ❌ Not available |
| Data ownership | ✅ Your infrastructure | ❌ Their servers |
| No tracking | ✅ | ❌ |
| Unlimited event types | ✅ Free tier | ❌ 1 on free plan |
| Calendar providers | 6 | 3 |
| Webhooks | ✅ Free tier | ❌ Paid only |
| SSO / OIDC | ✅ Free tier | ❌ Enterprise only |
| Telegram notifications | ✅ Built-in | ❌ |
| White-label | ✅ €5/mo | ❌ $16+/user/mo |

---

## Pricing

**Free** — self-hosted or cloud. Full feature set, all integrations, unlimited bookings, no credit card required.

**Pro — €5/month (cloud only).** White-label branding, priority support, early access to new features.

Self-hosting is always free. No feature restrictions, no licensing fees, ever.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local setup and the PR process. Bugs and feature requests go in [Issues](https://github.com/tymeslot/tymeslot/issues).

## License

[Elastic License 2.0](LICENSE) — free to use and self-host; commercial redistribution requires a separate agreement.

## About

Built by [Luka Karsten Breitig](https://lukabreitig.com) · Diletta Luna OÜ · Tallinn, Estonia

---

<div align="center">

Built with Elixir, Phoenix, and LiveView

</div>
