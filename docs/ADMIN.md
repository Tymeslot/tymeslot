# Admin access (self-hosted)

Tymeslot ships with a self-hosted admin UI at `/admin`. From it an admin can
toggle a small set of runtime settings (currently registration on/off,
password authentication on/off, video transcoding on/off) without redeploying
or restarting the server.

This guide covers how to **become an admin** in each supported deployment
target, since that step happens outside the UI.

## How admin status works

* The very first user to register on a fresh install is **automatically
  promoted to admin** (in the same database transaction as the insert). This
  only ever fires when the `users` table is empty.
* Once any user exists, the auto-promotion gate stays closed permanently.
  Subsequent admins must be promoted explicitly.
* Demoting all admins does **not** reopen the gate — you must run the
  promote task (or update the database directly).
* SaaS deployments have the admin UI disabled at the routing layer; the mix
  task and release helper refuse to run there.

## Promoting and demoting

There is one canonical interface, exposed two ways:

| Environment | Command |
|---|---|
| Development / running from source | `mix tymeslot.promote_admin <email>` |
| Packaged production release (Docker, Cloudron, Railway, …) | `bin/tymeslot rpc 'Tymeslot.Release.promote_admin("<email>")'` |

Symmetric commands exist for `demote_admin`. The user must already exist; the
commands do not create accounts.

The remainder of this document shows the exact shell incantation per
deployment target.

---

## Docker

Find the running container's name (commonly `tymeslot`), then `exec` into it:

```bash
docker exec -it tymeslot bin/tymeslot rpc 'Tymeslot.Release.promote_admin("you@example.com")'
```

To demote:

```bash
docker exec -it tymeslot bin/tymeslot rpc 'Tymeslot.Release.demote_admin("you@example.com")'
```

To list current admins:

```bash
docker exec -it tymeslot bin/tymeslot rpc 'Tymeslot.Release.list_admins()'
```

If you started the container with a different name, replace `tymeslot` with
that name. If Compose is in front of Docker, use
`docker compose exec tymeslot bin/tymeslot rpc '…'`.

---

## Cloudron

Cloudron provides a web terminal for every installed app. From the Cloudron
dashboard:

1. Open the Tymeslot app's tile.
2. Click **Terminal** (or run `cloudron exec --app <yourapp>` from the
   Cloudron CLI on your workstation).
3. Run:

   ```bash
   bin/tymeslot rpc 'Tymeslot.Release.promote_admin("you@example.com")'
   ```

The Cloudron CLI version of the same command:

```bash
cloudron exec --app tymeslot.yourdomain.com -- bin/tymeslot rpc 'Tymeslot.Release.promote_admin("you@example.com")'
```

`demote_admin` and `list_admins` work identically.

---

## Railway

Railway runs the same release artifact as Docker. Use Railway's CLI
(`railway run`) or the dashboard's web shell:

```bash
railway run bin/tymeslot rpc 'Tymeslot.Release.promote_admin("you@example.com")'
```

If you prefer the web shell, paste the same command into it directly.

---

## Source / development install

If you cloned the repo and run via `mix phx.server`, use the mix task:

```bash
mix tymeslot.promote_admin you@example.com
mix tymeslot.demote_admin you@example.com
```

The mix task delegates to `Tymeslot.Release.promote_admin/1`, so behaviour
is identical to the production path.

---

## Direct database access (last-resort recovery)

If you have lost mix-task and release-CLI access (for instance an operator
forgot every admin password and there are no remaining admins), promote
directly via SQL:

```sql
UPDATE users SET is_admin = true WHERE email = 'you@example.com';
```

This is intentionally not the recommended path — use it only when the
release helpers are unreachable. Every other recovery scenario is covered by
the commands above.

---

## What you can change from the admin UI

The settings page at `/admin` controls sign-up, sign-in methods, reCAPTCHA, admin alerts, meeting payments, booking analytics, email branding and default languages. Twelve of these settings also have an environment variable, and a variable that is set wins over the admin page:

| Setting | Environment variable | What it controls |
|---|---|---|
| `registration_enabled` | `REGISTRATION_ENABLED` | Whether new user registration is open |
| `password_auth_enabled` | `PASSWORD_AUTH_ENABLED` | Whether the email/password login form is available (SSO still works when disabled) |
| `google_auth_enabled` | `ENABLE_GOOGLE_AUTH` | Sign-in with Google |
| `github_auth_enabled` | `ENABLE_GITHUB_AUTH` | Sign-in with GitHub |
| `oauth_auth_enabled` | `ENABLE_OAUTH_AUTH` | Sign-in with a generic OpenID Connect provider |
| `recaptcha_signup_enabled` | `RECAPTCHA_SIGNUP_ENABLED` | reCAPTCHA on the sign-up form |
| `recaptcha_booking_enabled` | `RECAPTCHA_BOOKING_ENABLED` | reCAPTCHA on the booking form |
| `recaptcha_signup_min_score` | `RECAPTCHA_SIGNUP_MIN_SCORE` | Minimum reCAPTCHA score accepted at sign-up |
| `recaptcha_booking_min_score` | `RECAPTCHA_BOOKING_MIN_SCORE` | Minimum reCAPTCHA score accepted when booking |
| `admin_alerts_enabled` | `ADMIN_ALERTS_ENABLED` | Whether operational alerts are emailed |
| `admin_alert_email` | `ADMIN_ALERT_EMAIL` | Where operational alerts are sent |
| `meeting_payments_enabled` | `MEETING_PAYMENTS_ENABLED` | Whether hosts can take payment for meetings |

Each setting takes its value from the first of these layers that provides one:

1. **Environment variable**: the setting's variable from the table above, when it is set to a value it recognises (`true` or `false`; also `1`, `yes`, `0` and `no` for `ADMIN_ALERTS_ENABLED` and `MEETING_PAYMENTS_ENABLED`; a number from 0.0 to 1.0 for the two scores; any non-blank value for `ADMIN_ALERT_EMAIL`). An unrecognised value, such as `REGISTRATION_ENABLED=1`, logs a warning at boot and does not take precedence, so the admin page keeps managing the setting. The admin page shows the setting greyed out and names the variable, and refuses to change it.
2. **Admin page**: the value saved on `/admin`, stored in the database.
3. **Application config**: what `config.exs` or `runtime.exs` sets on boot, other than from the variable.
4. **Built-in default**: the value Core falls back to if none of the above is set.

Settings without a variable in the table only have the last three layers. The admin page shows the current source for each setting and lets you reset a saved value, so the setting falls back to the config layer or the default.

A value saved on the admin page before its variable was set is kept, not deleted. To manage that setting from the admin page again, remove the variable and restart: the stored value applies again. If a variable fixing a sign-in setting leaves no admin a way to sign in, Tymeslot logs an error at boot naming the variable; unset or correct it, then restart.
