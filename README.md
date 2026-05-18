<div align="center">

<img src="./priv/static/images/brand/logo-with-text.svg" alt="Tymeslot" height="72" />

### Open-source appointment scheduling. Self-host in minutes.

Booking pages, calendar sync, video rooms, automated emails — on your server.<br>
Built on Elixir/OTP so it keeps running while you're not looking.

[![License: Elastic-2.0](https://img.shields.io/badge/License-Elastic--2.0-blue.svg)](https://www.elastic.co/licensing/elastic-license)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-purple.svg)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8-orange.svg)](https://phoenixframework.org)
[![LiveView](https://img.shields.io/badge/LiveView-1.1-red.svg)](https://github.com/phoenixframework/phoenix_live_view)
[![GitHub stars](https://img.shields.io/github/stars/tymeslot/tymeslot?style=social)](https://github.com/tymeslot/tymeslot/stargazers)

[**Self-host with Docker →**](README-Docker.md) &nbsp;·&nbsp; [**Try the Cloud →**](https://tymeslot.app) &nbsp;·&nbsp; [**Docs →**](https://tymeslot.app/docs) &nbsp;·&nbsp; [**Issues →**](https://github.com/tymeslot/tymeslot/issues)

<br>

<img src="./priv/static/images/screenshots/dashboard.png" alt="Tymeslot dashboard" width="900" />

</div>

---

## Quick start

```bash
docker run --name tymeslot \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')" \
  -e PHX_HOST=localhost \
  -v tymeslot_data:/app/data \
  -v tymeslot_pg:/var/lib/postgresql/data \
  luka1thb/tymeslot:latest
```

Open [http://localhost:4000](http://localhost:4000) — your scheduling platform is live. For SMTP, TLS, reverse proxy, and external Postgres, see the [Docker guide](README-Docker.md).

> **Keep `tymeslot_pg` as a named volume.** Replacing it with a host path can fail on Docker Desktop, rootless Docker, and SELinux hosts. If you need a specific path, use [external Postgres](README-Docker.md#using-an-external-database).

---

## What you get

<table width="100%">
<tr>
<td width="50%" valign="top">

<img src="./priv/static/images/ui/spacer.png" width="450" height="1" alt="" />

### No double-bookings

<sub>━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━</sub>

Every connected calendar is checked at the moment of booking — one conflict anywhere blocks the slot everywhere.

</td>
<td width="50%" valign="top">

<img src="./priv/static/images/ui/spacer.png" width="450" height="1" alt="" />

### Availability that mirrors reality

<sub>━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━</sub>

Working hours, date-specific overrides, vacation blocks, per-meeting buffers, booking windows, minimum notice — without touching a calendar.

</td>
</tr>
<tr>
<td valign="top">

### Email that delivers

<sub>━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━</sub>

Responsive MJML templates, `.ics` on every send, configurable reminders, signed cancel and reschedule links — no logins, no support tickets.

</td>
<td valign="top">

### SSO-first auth

<sub>━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━</sub>

Email/password, Google, GitHub, plus generic OAuth/OIDC — Keycloak, Authentik, Okta, Azure AD. Disable registration or password auth independently.

</td>
</tr>
<tr>
<td valign="top">

### Embed anywhere

<sub>━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━</sub>

Inline, popup, or floating button. Signed, domain-locked tokens — your widget, only on your site.

</td>
<td valign="top">

### Privacy by design

<sub>━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━</sub>

AES-encrypted credentials at rest, no third-party analytics or tracking pixels, rate-limited public endpoints, HMAC-signed webhooks, CSRF and signed tokens throughout.

</td>
</tr>
</table>

Plus: two themes (Quill, Rhythm) with dark mode, five languages (English, German, Ukrainian, French, Italian), white-label option, Telegram notifications, drag-and-drop calendar dashboard, attendee-driven reschedule flow, integration health alerts, and **optional paid bookings via Stripe Connect** (see [Meeting payments](#meeting-payments) below).

---

## Integrations

**Calendars**

<table width="100%">
<tr>
<td width="25%" align="center"><img src="./priv/static/images/ui/spacer.png" width="220" height="1" alt="" /><br><img src="./priv/static/icons/providers/calendar/medium/google.png" alt="Google Calendar" height="44" /><br><sub>Google Calendar</sub></td>
<td width="25%" align="center"><img src="./priv/static/images/ui/spacer.png" width="220" height="1" alt="" /><br><img src="./priv/static/icons/providers/calendar/medium/outlook.png" alt="Outlook" height="44" /><br><sub>Outlook</sub></td>
<td width="25%" align="center"><img src="./priv/static/images/ui/spacer.png" width="220" height="1" alt="" /><br><img src="./priv/static/icons/providers/calendar/medium/caldav.png" alt="CalDAV" height="44" /><br><sub>CalDAV</sub></td>
<td width="25%" align="center"><img src="./priv/static/images/ui/spacer.png" width="220" height="1" alt="" /><br><img src="./priv/static/icons/providers/calendar/medium/nextcloud.png" alt="Nextcloud" height="44" /><br><sub>Nextcloud</sub></td>
</tr>
<tr>
<td align="center"><img src="./priv/static/icons/providers/calendar/medium/radicale.png" alt="Radicale" height="44" /><br><sub>Radicale</sub></td>
<td align="center"><img src="./priv/static/icons/providers/calendar/medium/zimbra.png" alt="Zimbra" height="44" /><br><sub>Zimbra</sub></td>
<td align="center"><img src="./priv/static/icons/providers/calendar/medium/mailbox_org.png" alt="mailbox.org" height="44" /><br><sub>mailbox.org</sub></td>
<td>&nbsp;</td>
</tr>
</table>

**Video & location**

<table width="100%">
<tr>
<td width="25%" align="center"><img src="./priv/static/images/ui/spacer.png" width="220" height="1" alt="" /><br><img src="./priv/static/icons/providers/video/medium/google_meet.png" alt="Google Meet" height="44" /><br><sub>Google Meet</sub></td>
<td width="25%" align="center"><img src="./priv/static/images/ui/spacer.png" width="220" height="1" alt="" /><br><img src="./priv/static/icons/providers/video/medium/teams.png" alt="Microsoft Teams" height="44" /><br><sub>Microsoft Teams</sub></td>
<td width="25%" align="center"><img src="./priv/static/images/ui/spacer.png" width="220" height="1" alt="" /><br><img src="./priv/static/icons/providers/video/medium/mirotalk.png" alt="MiroTalk P2P" height="44" /><br><sub>MiroTalk P2P</sub></td>
<td width="25%" align="center"><img src="./priv/static/images/ui/spacer.png" width="220" height="1" alt="" /><br><img src="./priv/static/icons/providers/video/medium/local.png" alt="In-Person / Phone" height="44" /><br><sub>In-Person / Phone</sub></td>
</tr>
<tr>
<td align="center"><img src="./priv/static/icons/providers/video/medium/custom.png" alt="Custom" height="44" /><br><sub>Custom Links</sub></td>
<td>&nbsp;</td>
<td>&nbsp;</td>
<td>&nbsp;</td>
</tr>
</table>

Webhooks (`meeting_created`, `meeting_cancelled`, `meeting_rescheduled`) plug into n8n, Zapier, Make, or your own backend. HMAC-signed payloads.

---

## Screenshots

<table>
<tr>
<td width="50%"><img src="./priv/static/images/screenshots/availability.png" alt="Booking page" /><br><sub><b>Booking page</b> — Quill or Rhythm theme, dark mode, five languages</sub></td>
<td width="50%"><img src="./priv/static/images/screenshots/embedding.png" alt="Embed widget" /><br><sub><b>Embed widget</b> — inline, popup, or floating button</sub></td>
</tr>
</table>

---

## Deploy

| Method | Guide | Notes |
|--------|-------|-------|
| **Docker** | [README-Docker.md](README-Docker.md) | Single container, Postgres included — recommended |
| **Cloudron** | [README-Cloudron.md](README-Cloudron.md) | One-click install, automatic updates |
| **Railway** | [Deploy →](https://railway.com/deploy/tymeslot) | One-click cloud, no server |
| **Managed Cloud** | [tymeslot.app](https://tymeslot.app) | Zero setup, free tier |

Full configuration reference (SMTP, OAuth, OIDC, reCAPTCHA, external Postgres, SSO-only mode): [Docker guide](README-Docker.md).

The first user to register on a fresh install is automatically promoted to admin and gets access to `/admin`, where they can toggle runtime settings (registration on/off, password auth on/off, video transcoding) without redeploying. For promoting additional admins on each deployment target — Docker, Cloudron, Railway, source — see [`docs/ADMIN.md`](docs/ADMIN.md).

---

## Meeting payments

Optional. Lets hosts charge attendees through Stripe at booking time. Off by default — self-hosters opt in by registering their own Stripe platform.

**Prerequisites**

1. Register a Stripe account for your instance and enable Stripe Connect.
2. Add Tymeslot as a Connect platform — your instance becomes the platform that hosts' Stripe accounts connect to.
3. Create a separate webhook endpoint in the Stripe dashboard for Connect events and copy its signing secret.

**Environment variables**

| Variable | Purpose |
|---|---|
| `STRIPE_SECRET_KEY` | Your platform's Stripe secret key (`sk_live_…` or `sk_test_…`). Required when `MEETING_PAYMENTS_ENABLED=true`. |
| `STRIPE_CONNECT_WEBHOOK_SECRET` | Signing secret for the Connect webhook endpoint. Required to verify connected-account events. |
| `MEETING_PAYMENTS_ENABLED` | Set to `true` to expose the payments dashboard and event-type payment toggle. Defaults to `false`. |
| `MEETING_PAYMENTS_APPLICATION_FEE_BP` | Optional platform fee, in basis points (`100` = 1%). Defaults to `0` so self-host operators never take a cut unless they explicitly opt in. Range `0`–`10000`. |

Once enabled, hosts connect their own Stripe account from **Dashboard → Payments**, pick a currency, and turn on `Require payment` on any event type. Direct charges flow into the host's Stripe balance on their existing payout schedule — Tymeslot never holds the funds.

---

## Stack

<div align="center">

<img src="https://img.shields.io/badge/Elixir-1.19-4B275F?logo=elixir&logoColor=white" alt="Elixir 1.19" />&nbsp;
<img src="https://img.shields.io/badge/OTP-28-A90533?logo=erlang&logoColor=white" alt="Erlang/OTP 28" />&nbsp;
<img src="https://img.shields.io/badge/Phoenix-1.8-FD4F00?logo=phoenixframework&logoColor=white" alt="Phoenix 1.8" />&nbsp;
<img src="https://img.shields.io/badge/LiveView-1.1-E34F26?logo=phoenixframework&logoColor=white" alt="LiveView 1.1" />&nbsp;
<img src="https://img.shields.io/badge/PostgreSQL-14+-4169E1?logo=postgresql&logoColor=white" alt="PostgreSQL 14+" />&nbsp;
<img src="https://img.shields.io/badge/Oban-Background_jobs-1E293B?logo=elixir&logoColor=white" alt="Oban" />

<img src="https://img.shields.io/badge/Tailwind_CSS-06B6D4?logo=tailwindcss&logoColor=white" alt="Tailwind CSS" />&nbsp;
<img src="https://img.shields.io/badge/Swoosh_+_MJML-Email-EF4444?logo=maildotru&logoColor=white" alt="Swoosh + MJML" />&nbsp;
<img src="https://img.shields.io/badge/Docker-2496ED?logo=docker&logoColor=white" alt="Docker" />&nbsp;
<img src="https://img.shields.io/badge/Cloudron-Self--host-1F6FEB" alt="Cloudron" />

</div>

---

## Pricing

<table width="100%">
<tr>
<td width="50%" valign="top">

<img src="./priv/static/images/ui/spacer.png" width="450" height="1" alt="" />

### Self-hosted

<h2>Free</h2>

<sub>forever — Elastic Licence 2.0</sub>

<br>

✓&nbsp;Full feature set<br>
✓&nbsp;All integrations<br>
✓&nbsp;Unlimited bookings<br>
✓&nbsp;Community support

</td>
<td width="50%" valign="top">

<img src="./priv/static/images/ui/spacer.png" width="450" height="1" alt="" />

### Managed Cloud

<h2>Free <small>·</small> €5<small>/mo</small></h2>

<sub>free plan — €5/mo for Pro</sub>

<br>

✓&nbsp;Zero maintenance<br>
✓&nbsp;Automatic updates<br>
✓&nbsp;Free plan included<br>
✓&nbsp;Priority support

</td>
</tr>
<tr>
<td valign="bottom">

<a href="README-Docker.md"><b>Self-host with Docker →</b></a>

</td>
<td valign="bottom">

<a href="https://tymeslot.app"><b>Try the cloud →</b></a>

</td>
</tr>
</table>

---

## Contributing & licence

PRs and issues welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under the [Elastic License 2.0](LICENSE) — free to use and self-host; commercial redistribution requires a separate agreement.

Report security vulnerabilities via the [contact page](https://tymeslot.app/contact).

Built by [Luka Karsten Breitig](https://lukabreitig.com) · Diletta Luna OÜ · Tallinn, Estonia.

<div align="center"><sub>Built with Elixir, Phoenix, and LiveView</sub></div>
