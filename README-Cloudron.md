# Tymeslot on Cloudron

> For an overview of Tymeslot's features, see the [Core README](README.md).

Tymeslot is in the [Cloudron App Store](https://www.cloudron.io/store/tymeslot.html). The package is maintained by Cloudron in its own repository, [git.cloudron.io/packages/tymeslot-app](https://git.cloudron.io/packages/tymeslot-app): for every Tymeslot release it builds an image from the tagged source of this repository, and Cloudron offers it to installed apps as an update. This repository does not publish a Cloudron package of its own.

On Cloudron you get, with no extra setup:

- **TLS certificates** from Cloudron's reverse proxy
- **PostgreSQL**, provisioned and backed up by the platform
- **Email** through Cloudron's mail relay
- **Single sign-on** with Cloudron accounts, over OIDC
- **Health checks, backups and updates** handled by the platform

Cloudron's own notes for the package are at [docs.cloudron.io/packages/tymeslot](https://docs.cloudron.io/packages/tymeslot), and questions about it go to the [Tymeslot category of the Cloudron forum](https://forum.cloudron.io/category/449/tymeslot). Bugs in Tymeslot itself go to this repository's issues.

---

## Installing

You need Cloudron 9.1.0 or later and a domain configured in it.

1. Open your Cloudron dashboard and go to **App Store**.
2. Search for **Tymeslot** and open it.
3. Choose a location (e.g. `tymeslot.yourdomain.com`) and click **Install**.

The first user to register on a fresh install becomes the admin (see [Becoming an admin](#becoming-an-admin)).

> **Installed earlier with Install via URL?** The community package that was installed from `https://raw.githubusercontent.com/Tymeslot/tymeslot/main/CloudronVersions.json` is retired and receives no further updates. The App Store version is a separate app, so an existing installation does not move over by itself: install Tymeslot from the App Store as a new app.

### What the package does on each start

- Generates `SECRET_KEY_BASE` on first run and keeps it in `/app/data/secret_key_base`, unless you set one in the app's environment.
- Creates `/app/data/uploads` (avatars and theme backgrounds), `/app/data/tzdata` and `/app/data/logs`.
- Runs the database migrations, then starts Tymeslot.

The image sets `DEPLOYMENT_TYPE=cloudron`, which makes Tymeslot read its database settings from the PostgreSQL addon (`CLOUDRON_POSTGRESQL_*`), send mail through the sendmail addon, offer sign-in through the OIDC addon, and keep a rotating copy of its log under `/app/data/logs`. Everything under `/app/data` is included in Cloudron's backups. The health check is `/healthcheck`.

---

## Configuration

Configure Tymeslot with environment variables, set with `cloudron env set` or in the app's **Environment** tab in the dashboard. Several can be set in one command; the app restarts automatically.

```bash
cloudron env set --app tymeslot.yourdomain.com PHX_HOST=tymeslot.yourdomain.com

# Confirm current values
cloudron env list --app tymeslot.yourdomain.com
```

`PHX_HOST` is the domain every link Tymeslot generates is built from. Without it Tymeslot uses `CLOUDRON_APP_DOMAIN`, which Cloudron supplies, but setting it explicitly is recommended.

Every supported variable, with its default, is listed in [`.env.example`](.env.example) and explained in the [Docker guide](README-Docker.md). Cloudron supplies the port and the addon settings itself, so leave `PORT`, `DATABASE_URL`, `DEPLOYMENT_TYPE` and the `CLOUDRON_*` variables alone.

Tymeslot also reads `/app/data/.env` at boot if the file exists, and applies any key the environment does not already set. The package does not create the file; values set with `cloudron env set` are the ones the dashboard shows, and they always win over the file.

### Running one-off commands

Commands that act on the running app use `rpc` and need nothing else:

```bash
cloudron exec --app tymeslot.yourdomain.com -- /app/bin/tymeslot rpc 'Tymeslot.Release.promote_admin("you@example.com")'
```

Commands run with `eval` start a separate VM that reads the configuration again, and so need `SECRET_KEY_BASE`, which the package exports only to the app itself. Read it from the file the package keeps it in (an exported value, set with `cloudron env set`, takes precedence):

```bash
cloudron exec --app tymeslot.yourdomain.com -- sh -c \
  'SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(cat /app/data/secret_key_base)}" /app/bin/tymeslot eval "Tymeslot.Release.Encryption.key_report()"'
```

The `eval` commands below are written in this form.

### Becoming an admin

The first user to register on a fresh install is promoted to admin automatically. To promote further users, open the app's **Terminal** in the Cloudron dashboard and run:

```bash
/app/bin/tymeslot rpc 'Tymeslot.Release.promote_admin("you@example.com")'
```

or run the `cloudron exec` form above from your workstation. See [`docs/ADMIN.md`](docs/ADMIN.md) for demoting, listing and recovery.

### Email and single sign-on

Tymeslot uses Cloudron's addons on its own, with no variables to set:

- **Email (sendmail addon):** mail goes through Cloudron's relay, with the sender address and name Cloudron supplies. No `SMTP_*` or `EMAIL_ADAPTER` configuration is needed.
- **Single sign-on (OIDC addon):** the login page offers Cloudron's identity provider, under the name the Cloudron admin gave it (or "SSO"). No `OAUTH_*` configuration is needed.

To override them:

- **Email:** set `EMAIL_ADAPTER` to use another provider instead of the relay, with that provider's variables:

  ```bash
  cloudron env set --app tymeslot.yourdomain.com EMAIL_ADAPTER=postmark POSTMARK_API_KEY=your_postmark_api_key EMAIL_FROM_ADDRESS=noreply@yourdomain.com EMAIL_FROM_NAME=Tymeslot
  ```

  | `EMAIL_ADAPTER` | Additional variables |
  |---|---|
  | `postmark` | `POSTMARK_API_KEY` |
  | `sendgrid` | `SENDGRID_API_KEY` |
  | `mailgun` | `MAILGUN_API_KEY`, `MAILGUN_DOMAIN`, optional `MAILGUN_BASE_URL` for EU accounts |
  | `ahasend` | `AHASEND_API_KEY`, `AHASEND_ACCOUNT_ID` |
  | `smtp` | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` |

  An `EMAIL_ADAPTER` value Tymeslot does not recognise stops the app at boot rather than discarding mail silently, so a typo shows up straight away in `cloudron logs`. The SMTP options (implicit TLS, self-signed relays, middlebox compatibility) are described in the [Docker guide](README-Docker.md).

- **SSO:** set `ENABLE_OAUTH_AUTH=false` to turn SSO off, or `ENABLE_OAUTH_AUTH=true` with your own `OAUTH_*` variables to use a different identity provider. Either value also locks the SSO switch on the `/admin` settings page; to keep it adjustable there, leave the variable unset.

### Calendar, video and social sign-in providers

Google, Microsoft (Outlook and Teams) and GitHub need OAuth credentials you register with each provider. Set them with `cloudron env set`:

```bash
# Google sign-in, Calendar and Meet
cloudron env set --app tymeslot.yourdomain.com ENABLE_GOOGLE_AUTH=true GOOGLE_CLIENT_ID=your_id GOOGLE_CLIENT_SECRET=your_secret GOOGLE_STATE_SECRET=$(openssl rand -base64 32 | tr -d '\n')

# Microsoft Outlook and Teams
cloudron env set --app tymeslot.yourdomain.com OUTLOOK_CLIENT_ID=your_id OUTLOOK_CLIENT_SECRET=your_secret OUTLOOK_STATE_SECRET=$(openssl rand -base64 32 | tr -d '\n')

# GitHub sign-in
cloudron env set --app tymeslot.yourdomain.com ENABLE_GITHUB_AUTH=true GITHUB_CLIENT_ID=your_id GITHUB_CLIENT_SECRET=your_secret
```

The redirect URIs and API permissions each provider needs are in the [OAuth setup guide](README-Docker.md#oauth-provider-setup); use your Cloudron domain in them. CalDAV calendars (Nextcloud, Fastmail, iCloud and others) need no server-side configuration.

---

## Data-at-rest encryption

Integration credentials (calendar tokens, CalDAV passwords, video API keys, Slack and Telegram tokens, webhook secrets) are encrypted at rest with AES-256-GCM. Without a dedicated `DATA_ENCRYPTION_KEY`, the key is derived from `SECRET_KEY_BASE`, so replacing `SECRET_KEY_BASE` would make every stored credential undecryptable. A dedicated key decouples the two.

1. Check whether the package has already generated a key for you:

   ```bash
   cloudron exec --app tymeslot.yourdomain.com -- ls -l /app/data/data_encryption_key
   ```

   If the file exists, the package manages the key: do not set `DATA_ENCRYPTION_KEY` yourself, and go on to step 3.

2. Otherwise, set one. Keep a copy somewhere safe and never change it: losing it makes stored credentials unrecoverable, and to replace it you rotate it (below).

   ```bash
   cloudron env set --app tymeslot.yourdomain.com DATA_ENCRYPTION_KEY=$(openssl rand -base64 48 | tr -d '\n')
   ```

   New values are written under the key from the restart on. Existing values keep decrypting under the old key, so nothing breaks.

3. Move existing values onto the key. Re-run until it reports `migrated values: 0`; the sweep is idempotent and safe to run while the app serves traffic.

   ```bash
   cloudron exec --app tymeslot.yourdomain.com -- sh -c \
     'SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(cat /app/data/secret_key_base)}" /app/bin/tymeslot eval "Tymeslot.Release.Encryption.reencrypt_credentials()"'
   ```

4. Check that nothing is left on the old key with `Tymeslot.Release.Encryption.key_report()` (the command under [Running one-off commands](#running-one-off-commands)). Once no `v0` appears, retire it:

   ```bash
   cloudron env set --app tymeslot.yourdomain.com LEGACY_KEY_RETIRED=true
   ```

   From then on `SECRET_KEY_BASE` plays no part in data-at-rest encryption.

**Rotating the key.** Never rotate by changing `DATA_ENCRYPTION_KEY`; add keys with `DATA_ENCRYPTION_KEYS` instead. The procedure, and what each report means, is in [README-Docker.md, "Rotating the data key"](README-Docker.md#rotating-the-data-key). On Cloudron, set the variable with `cloudron env set`; a Cloudron app runs as a single container, stopped before its replacement starts, so phases 1 and 2 may be one restart: `DATA_ENCRYPTION_KEYS=2:<new key>,1:<current key>`. Back up the app first. If the package generated your current key, it is the content of `/app/data/data_encryption_key`.

---

## Logs and error tracking

```bash
cloudron logs --app tymeslot.yourdomain.com --follow
```

Tymeslot writes structured JSON logs to stdout. Personal data is kept out of them: email addresses and the names, recipients and subjects of the emails it sends are redacted, and a visitor's IP address is cut down to its network (the first three parts of an IPv4 address, the first three groups of an IPv6 one) before it is written. Security events (sign-ins, rate-limit hits, lockouts) still record that network and the browser's user agent, so an operator can tell one source of traffic from another. Rate limiting and account lockout use the full address, in memory only, for the few minutes they need it.

On Cloudron the same stream is also kept in rotating, gzipped files under `/app/data/logs/` (and so in the app's backups): 30 files of 10 MB each by default, which is a few weeks at typical traffic. The files rotate by size, not by age, so a quiet instance keeps them for longer. Lower `LOG_FILE_MAX_FILES` or `LOG_FILE_MAX_BYTES` to keep less; the `LOG FILE` section of `.env.example` describes both. Cloudron's own log viewer is separate and follows Cloudron's retention.

Tymeslot records every unexpected error, process crash and failed background job in the app's own database, with the user id and the request, LiveView or job it happened in (request path, parameters and headers included; credentials, tokens, cookies, email addresses and the client's IP address are redacted first). Records of an error not seen for 30 days are resolved, and deleted 30 days later. To store nothing, set `ERROR_TRACKING_ENABLED=false`; errors are then only logged. The `ERROR TRACKING` section of `.env.example` lists exactly what is kept.

---

## Updates

Cloudron checks for new versions of the package and shows an update in the dashboard; apply it there, or with:

```bash
cloudron update --app tymeslot.yourdomain.com
```

The package picks up each Tymeslot release from this repository's GitHub releases; its own version number is not Tymeslot's, which the dashboard shows as the upstream version. Release notes for each version are on this repository's [GitHub releases](https://github.com/Tymeslot/tymeslot/releases).

### Upgrading to a release that strips upload metadata

Avatars and theme backgrounds no longer keep the location, capture time and camera or phone details that photos and videos often carry. Files uploaded before the update are cleaned automatically, once, in the background on the first start after updating; the app log reports `Upload metadata sweep finished` when it is done.

To run the clean-up again by hand, for instance after restoring an old copy of `/app/data/uploads`, run it inside the running app, which keeps the files' owner unchanged. It is safe to repeat.

```bash
cloudron exec --app tymeslot.yourdomain.com -- /app/bin/tymeslot rpc 'Tymeslot.Release.strip_upload_metadata()'
```

QuickTime (`.mov`) videos are no longer accepted as theme backgrounds; a `.mov` background you already have keeps working.

---

## Troubleshooting

**The app will not start.** Check `cloudron logs`: Tymeslot stops at boot when a setting is incomplete, and names the variable. Common causes are an explicit `EMAIL_ADAPTER` without its provider's credentials, or `ENABLE_OAUTH_AUTH=true` without the OAuth endpoints.

**Pages load but never respond to clicks.** Check that `PHX_HOST` matches the app's domain.

**OAuth sign-in or calendar connection fails.** Check that the redirect URIs registered with the provider match your domain exactly.

**Migrations.** The package migrates on every start. To run pending migrations by hand:

```bash
cloudron exec --app tymeslot.yourdomain.com -- sh -c \
  'SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(cat /app/data/secret_key_base)}" /app/bin/tymeslot eval "Tymeslot.Release.migrate()"'
```

**Database console.**

```bash
cloudron exec --app tymeslot.yourdomain.com -- sh -c 'psql "$CLOUDRON_POSTGRESQL_URL"'
```

**Memory.** The package asks for 1 GB, which suits most instances; change it in the app's **Resources** tab.

---

## Running a fork

To run your own build of Tymeslot on Cloudron, clone the [package repository](https://git.cloudron.io/packages/tymeslot-app), point its `Dockerfile` at your fork's source, then build and install it with the Cloudron CLI (`cloudron builder build`, then `cloudron install --image <image>`). An app installed that way is updated by you, not by the App Store.
