# Per user SMTP foundations

Phase 1 provides an internal domain API and a secure SMTP transport for one
sending identity per user. It does not yet route booking notifications through
that identity or expose dashboard controls. Those integrations follow in the
[extension plan](plans/per-user-smtp.md).

## Deployment opt in

`USER_SMTP_ENABLED` defaults to `false`. It accepts exactly `true` or `false`;
an empty value or typo fails startup. When it is unset, the application keeps
its configured default, which an embedding application may override.

Set the flag in the deployment environment or the `.env` file used by Docker
Compose. The provided Compose configurations forward `.env` with `env_file`;
the Docker and Railway images also default the flag to `false`.

The flag guards testing and activation at the domain and transport boundaries.
Leave it disabled until explicitly testing the foundation. Enabling it does
not change the platform mailer, account recovery mail, or notification routing
in phase 1.

## Settings and credentials

Each user has at most one settings record. The domain derives ownership from
the acting user and scopes database queries by that owner. Ordinary settings
reads return a redacted view. SMTP username and password are encrypted with
the existing application keyring and included in the credential rotation
sweep. Follow the [Docker encryption procedure](../README-Docker.md#data-at-rest-encryption)
when rotating encryption keys; losing a key prevents use of credentials
encrypted under it.

The configuration accepts a public SMTP hostname, port 465 with implicit TLS
or port 587 with required STARTTLS, credentials, a From address, and a From
display name. Users need an SMTP account that authorizes their chosen From
address. Password and app-password authentication are supported; OAuth is
outside this foundation.

A blank password during an edit preserves the existing secret. Removing the
settings deletes the stored credentials. Account deletion cascades to the
settings record. Credentials must never appear in job arguments, browser
responses, email metadata, or application logs.

## Testing and activation

Test messages go only to the acting user's verified account email. A test
must succeed before its settings revision can be enabled. Relay acceptance
does not prove inbox delivery, SPF/DKIM/DMARC configuration, or mailbox
ownership beyond the user's existing account verification.

Failed replacement tests preserve the active stored configuration. A
concurrent edit, disable, or deletion invalidates a stale save. Configuration
IDs and revisions bind test results and lifecycle actions to the exact saved
identity, including when an identity is deleted and recreated.

The internal context is `Tymeslot.EmailSending`. Creation uses
`test_and_save_settings(current_user, attrs, :new)`. Subsequent edits,
activation, disablement, and deletion use
`Tymeslot.EmailSending.Settings.version(settings)` as their expected version.
This token contains both the configuration ID and revision; a revision alone
cannot distinguish a recreated identity from an old form.

The existing rate limiter bounds test sends to five attempts per owner per
ten minutes, including rejected relay attempts. Its counters are node-local
and reset on restart, consistent with the application's other interactive
connection limits. Invalid settings and disabled features do not open a
connection or spend this budget.

## Connection policy

User SMTP requires certificate verification, encrypted authentication, and an
SMTP server that offers AUTH. It does not inherit the platform adapter's
optional unauthenticated relay behavior. Private/local destinations and
nonstandard ports are rejected. All returned IPv4/IPv6 addresses are checked,
and connections use an approved address while retaining the original
hostname for TLS certificate validation. Each connection resolves and checks
the destination again.

Application-owned resolver and CA test fixtures allow isolated loopback relay
tests. They are not user settings or environment variable escape hatches.

## Disablement and recovery

Set `USER_SMTP_ENABLED=false` and restart to disable all user SMTP connection
and activation operations. The additive table and encrypted values can remain
in place across a code rollback. Existing platform SMTP/API-provider delivery
continues to follow its deployment configuration.

Repair credentials with a new successful test, then enable the tested
revision. Retain encryption keys until the existing re-encryption sweep
confirms that no stored credentials require them. Test and connection errors
must expose sanitized categories rather than raw provider replies.
