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

| Setting | What it controls |
|---|---|
| `registration_enabled` | Whether new user registration is open |
| `password_auth_enabled` | Whether the email/password login form is available (OAuth still works when disabled) |

Each setting has three layers of precedence:

1. **DB override** — the value set from the admin UI (highest priority).
2. **Application config / environment variable** — what `config.exs` or
   `runtime.exs` sees on boot.
3. **Built-in default** — the value Core falls back to if neither of the
   above is set.

The admin UI shows you the current source for each setting and lets you
reset the DB override to fall back to the config/environment layer.
