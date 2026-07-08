<div align="center">

<img src="./priv/static/images/brand/logo-with-text.svg" alt="Tymeslot" height="76" />

<h3>Scheduling software that stays yours.</h3>

<p>
Booking pages, calendar sync, video rooms and automated emails — running on <b>your</b> server, under your control.<br />
Built on Elixir/OTP, so it keeps running while you sleep.
</p>

<p>
<a href="https://www.gnu.org/licenses/agpl-3.0.html"><img src="https://img.shields.io/badge/Licence-AGPL--3.0-1F6FEB.svg" alt="Licence: AGPL-3.0" /></a>
<a href="https://elixir-lang.org"><img src="https://img.shields.io/badge/Elixir-1.20-4B275F.svg?logo=elixir&logoColor=white" alt="Elixir" /></a>
<a href="https://phoenixframework.org"><img src="https://img.shields.io/badge/Phoenix-1.8-FD4F00.svg?logo=phoenixframework&logoColor=white" alt="Phoenix" /></a>
<a href="https://github.com/phoenixframework/phoenix_live_view"><img src="https://img.shields.io/badge/LiveView-1.1-E34F26.svg" alt="LiveView" /></a>
<a href="https://github.com/tymeslot/tymeslot/releases"><img src="https://img.shields.io/github/v/release/tymeslot/tymeslot?label=release&color=2ea043" alt="Latest release" /></a>
<a href="https://github.com/tymeslot/tymeslot/commits"><img src="https://img.shields.io/github/last-commit/tymeslot/tymeslot?label=last%20commit&color=2ea043" alt="Last commit" /></a>
<a href="https://github.com/tymeslot/tymeslot/stargazers"><img src="https://img.shields.io/github/stars/tymeslot/tymeslot?style=social" alt="GitHub stars" /></a>
</p>

<p>
<b><a href="#quick-start">Self-host with Docker →</a></b> &nbsp;·&nbsp;
<b><a href="https://tymeslot.app">Try the Cloud →</a></b> &nbsp;·&nbsp;
<b><a href="https://tymeslot.app/demo-theme-1">Live demo →</a></b> &nbsp;·&nbsp;
<b><a href="https://tymeslot.app/docs">Docs →</a></b> &nbsp;·&nbsp;
<b><a href="https://github.com/tymeslot/tymeslot/issues">Issues →</a></b>
</p>

<br />

<img src="./priv/static/images/demo/quill.gif" alt="Booking a meeting on a Tymeslot page — pick a duration, choose a time, confirm" width="900" />

<sub>A real booking, start to finish: pick a duration, choose a time, done. &nbsp;·&nbsp; <a href="./priv/static/images/demo/quill.mp4">Watch in HD →</a></sub>

</div>

<br />

> **Open source, and staying that way.** Calendly is closed SaaS. Cal.com relicensed away from open source in 2026. Tymeslot's source stays public and self-hostable under the [GNU AGPLv3](LICENSE) — what you run today, you can keep running tomorrow.
>
> **Actively developed.** Tymeslot is the engine behind [tymeslot.app](https://tymeslot.app), our managed cloud — so the code you self-host is the same code we run in production for paying customers. New releases ship regularly; see the [releases](https://github.com/tymeslot/tymeslot/releases).

---

## Quick start

One command. Postgres is bundled, so there is nothing else to install.

```bash
docker run --name tymeslot \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')" \
  -e PHX_HOST=localhost \
  -v tymeslot_data:/app/data \
  -v tymeslot_pg:/var/lib/postgresql/data \
  luka1thb/tymeslot:latest
```

Open **[http://localhost:4000](http://localhost:4000)** — your scheduling platform is live. The first account you create becomes the admin. For SMTP, TLS, a reverse proxy and external Postgres, see the [Docker guide](README-Docker.md).

> **Keep `tymeslot_pg` as a named volume.** Swapping it for a host path can fail on Docker Desktop, rootless Docker and SELinux hosts. If you need a specific location, use [external Postgres](README-Docker.md#using-an-external-database) instead.

---

## Everything you need to take bookings

No add-ons, no per-feature upsells. It all ships in the box.

### One place to run your day

Upcoming meetings, quick actions and your whole setup on a single screen. No hunting through menus to change how you take bookings.

![Tymeslot dashboard — overview with upcoming meetings and quick actions](./priv/static/images/screenshots/dashboard.webp)

### Availability that mirrors reality

Working hours, date-specific overrides, holiday blocks, per-meeting buffers, booking windows and minimum notice — set once, and your booking page reflects exactly when you are free.

![Availability editor — weekly schedule with per-day hours and breaks](./priv/static/images/screenshots/availability.webp)

### Embed it anywhere

Inline on a page, a popup, or a floating button. Copy the snippet, paste it on your site. Tokens are signed and domain-locked, so your widget only runs where you put it.

![Embed & share — inline, popup and floating embed options with code snippets](./priv/static/images/screenshots/embed.webp)

### Never double-booked

Every connected calendar is checked the moment someone books. One conflict anywhere blocks the slot everywhere — across Google, Outlook, CalDAV and the rest.

---

## And there's more under the hood

- **Email that delivers** — responsive templates, an `.ics` file on every send, configurable reminders, and signed cancel/reschedule links that need no login.
- **Ask the right questions** — add custom questions to any meeting type, so you walk into every call already briefed.
- **SSO-first auth** — email/password, Google, GitHub, plus generic OAuth/OIDC for Keycloak, Authentik, Okta and Azure AD. Disable registration or password login independently.
- **Privacy by design** — credentials encrypted at rest, no third-party trackers or analytics pixels, rate-limited public endpoints, HMAC-signed webhooks, CSRF and signed tokens throughout.
- **Automate everything** — `meeting_created`, `meeting_cancelled` and `meeting_rescheduled` webhooks plug straight into n8n, Zapier, Make or your own backend.
- **Make it yours** — two booking-page themes (Quill and Rhythm) with dark mode and white-label options.
- **Speaks your language** — English, German, Ukrainian, French and Italian, with Slack/Telegram notifications.
- **Get paid to meet** — optional paid bookings through [Stripe Connect](#meeting-payments), off by default and fee-free for self-hosters.

---

## Works with your stack

<b>Calendars</b> — sync availability and write confirmed meetings back, both ways.

<table align="center">
<tr>
<td align="center"><img src="./priv/static/icons/providers/calendar/medium/google.png" alt="Google Calendar" height="40" /><br /><sub>Google Calendar</sub></td>
<td align="center"><img src="./priv/static/icons/providers/calendar/medium/outlook.png" alt="Outlook" height="40" /><br /><sub>Outlook</sub></td>
<td align="center"><img src="./priv/static/icons/providers/calendar/apple.svg" alt="Apple iCloud" height="40" /><br /><sub>Apple iCloud</sub></td>
<td align="center"><img src="./priv/static/icons/providers/calendar/medium/caldav.png" alt="CalDAV" height="40" /><br /><sub>CalDAV</sub></td>
</tr>
<tr>
<td align="center"><img src="./priv/static/icons/providers/calendar/medium/nextcloud.png" alt="Nextcloud" height="40" /><br /><sub>Nextcloud</sub></td>
<td align="center"><img src="./priv/static/icons/providers/calendar/medium/radicale.png" alt="Radicale" height="40" /><br /><sub>Radicale</sub></td>
<td align="center"><img src="./priv/static/icons/providers/calendar/medium/zimbra.png" alt="Zimbra" height="40" /><br /><sub>Zimbra</sub></td>
<td align="center"><img src="./priv/static/icons/providers/calendar/medium/baikal.png" alt="Baikal" height="40" /><br /><sub>Baikal</sub></td>
</tr>
<tr>
<td align="center"><img src="./priv/static/icons/providers/calendar/medium/mailbox_org.png" alt="mailbox.org" height="40" /><br /><sub>mailbox.org</sub></td>
<td></td>
<td></td>
<td></td>
</tr>
</table>

<b>Video &amp; location</b> — auto-create a meeting room (or set a place) when a booking is confirmed.

<table align="center">
<tr>
<td align="center"><img src="./priv/static/icons/providers/video/medium/google_meet.png" alt="Google Meet" height="40" /><br /><sub>Google Meet</sub></td>
<td align="center"><img src="./priv/static/icons/providers/video/medium/teams.png" alt="Microsoft Teams" height="40" /><br /><sub>Microsoft Teams</sub></td>
<td align="center"><img src="./priv/static/icons/providers/video/medium/zoom.png" alt="Zoom" height="40" /><br /><sub>Zoom</sub></td>
</tr>
<tr>
<td align="center"><img src="./priv/static/icons/providers/video/medium/mirotalk.png" alt="MiroTalk P2P" height="40" /><br /><sub>MiroTalk P2P</sub></td>
<td align="center"><img src="./priv/static/icons/providers/video/medium/in_person.png" alt="In person / phone" height="40" /><br /><sub>In person / phone</sub></td>
<td align="center"><img src="./priv/static/icons/providers/video/medium/custom.png" alt="Custom link" height="40" /><br /><sub>Custom link</sub></td>
</tr>
</table>

---

## Deploy your way

| Method | Guide | Notes |
|---|---|---|
| **Docker** | [README-Docker.md](README-Docker.md) | Single container, Postgres included — recommended |
| **Cloudron** | [README-Cloudron.md](README-Cloudron.md) | One-click install, automatic updates |
| **Railway** | [Deploy →](https://railway.com/deploy/tymeslot) | One-click cloud, no server to manage |
| **Managed Cloud** | [tymeslot.app](https://tymeslot.app) | Zero setup, free plan included |

Full configuration reference — SMTP, OAuth, OIDC, reCAPTCHA, external Postgres, SSO-only mode — lives in the [Docker guide](README-Docker.md). The first user to register on a fresh install becomes admin and gets `/admin`, where runtime settings (registration on/off, password auth, video transcoding) can be toggled without a redeploy. For promoting further admins on each target, see [`docs/ADMIN.md`](docs/ADMIN.md).

---

## Meeting payments

Optional. Charge attendees through Stripe at booking time. Off by default — self-hosters opt in by registering their own Stripe platform, and Tymeslot never holds the funds or takes a cut unless you set one.

<details>
<summary><b>Set up Stripe Connect</b></summary>

<br />

**Prerequisites**

1. Register a Stripe account for your instance and enable Stripe Connect.
2. Add Tymeslot as a Connect platform — your instance becomes the platform that hosts' Stripe accounts connect to.
3. Create a separate webhook endpoint in the Stripe dashboard for Connect events and copy its signing secret.

**Environment variables**

| Variable | Purpose |
|---|---|
| `STRIPE_SECRET_KEY` | Your platform's Stripe secret key (`sk_live_…` or `sk_test_…`). Required when `MEETING_PAYMENTS_ENABLED=true`. |
| `STRIPE_CONNECT_WEBHOOK_SECRET` | Signing secret for the Connect webhook endpoint. Required to verify connected-account events. |
| `MEETING_PAYMENTS_ENABLED` | Set to `true` to expose the payments dashboard and the per-event payment toggle. Defaults to `false`. |
| `MEETING_PAYMENTS_APPLICATION_FEE_BP` | Optional platform fee in basis points (`100` = 1%). Defaults to `0`, so self-hosters never take a cut unless they opt in. Range `0`–`10000`. |

Once enabled, hosts connect their own Stripe account from **Dashboard → Integrations → Payments**, pick a currency, and switch on **Require payment** for any event type. Direct charges flow into the host's Stripe balance on their existing payout schedule.

</details>

---

## Built on

<div align="center">

<img src="https://img.shields.io/badge/Elixir-1.20-4B275F?logo=elixir&logoColor=white" alt="Elixir 1.20" />&nbsp;
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

### Self-hosted — free, forever

The full feature set, every integration, unlimited bookings. Yours under the GNU AGPLv3, with community support. **[Self-host with Docker →](#quick-start)**

### Managed Cloud — free plan, €9/mo for Pro

Zero maintenance, automatic updates and priority support. Start free; upgrade to Pro when you grow. **[Try the Cloud →](https://tymeslot.app)** — 7-day Pro trial, no card required.

---

## Star us & contribute

If Tymeslot is useful to you, **[star the repo](https://github.com/tymeslot/tymeslot)** — it's the single biggest thing you can do to help others find it.

PRs and issues are welcome — start with [CONTRIBUTING.md](CONTRIBUTING.md). Found a security issue? Please report it via the [contact page](https://tymeslot.app/contact) rather than a public issue.

Tymeslot is better thanks to its contributors — see [CONTRIBUTORS.md](CONTRIBUTORS.md), with special thanks to [@dani](https://github.com/dani) for generic OAuth, French localisation and a stream of CalDAV fixes.

## Licence

Open source under the [GNU AGPLv3](LICENSE) — free to use, self-host, modify and redistribute; if you run a modified version as a network service, share your changes under the same licence.

The licence covers the **code**. The **Tymeslot name and logo** are trademarks of Diletta Luna OÜ — forks are welcome, but must travel under their own name. See [TRADEMARK.md](TRADEMARK.md).

<br />

<div align="center">
<sub>Built with Elixir, Phoenix and LiveView · by the Tymeslot team at Diletta Luna OÜ · Tallinn, Estonia</sub>
</div>
