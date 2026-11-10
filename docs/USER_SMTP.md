# Per user SMTP

Each user can configure one secure SMTP identity for scheduling notifications
under dashboard **Profile > Email sending**. The
[extension plan](plans/per-user-smtp.md) records the implementation phases.

## Deployment opt in

`USER_SMTP_ENABLED` defaults to `false`. It accepts exactly `true` or `false`;
an empty value or typo fails startup. When it is unset, the application keeps
its configured default, which an embedding application may override.

Set the flag in the deployment environment or the `.env` file used by Docker
Compose. The provided Compose configurations forward `.env` with `env_file`;
the Docker and Railway images also default the flag to `false`.

The flag guards testing, activation, scheduling routing and the transport boundary.
Enable it to expose the dashboard controls and route scheduling email through
users' tested, enabled identities.
The platform mailer and account recovery mail retain their deployment settings.

## Message coverage

Booking confirmations, reminders, cancellations, rescheduling, approvals and
outcomes, guest invitations, group seats, registration-close notices and booking
end-change notices use the organizer's enabled identity. Every recipient copy,
including the organizer's own copy, uses that organizer's account. A recipient's
SMTP settings never select the sender. Reply-To continues to reach the other
booking party when appropriate; calendar attachments retain their UID, sequence,
actual organizer address and existing RSVP behavior.

Poll invitations, personal voting links, vote receipts, deadline reminders,
new-time and cancellation notices, host nudges and vote digests use the poll
host's identity. Dashboard calendar invitations, updates and cancellations
use the event owner's identity, including recurring-event snapshots. Their
calendar attachments retain the actual organizer, UID, sequence and iTIP method.
Booking refund notices use the payment's saved host ID, even if the meeting
has been deleted. Receipts and payment-related booking outcomes included in
booking confirmations and cancellations use the same booking policy.

Without an enabled custom identity, scheduling email uses the platform sender.
Account, security, administration, integration-health and external calendar
alerts remain platform messages. Stripe account restrictions, payout and dispute
notices, deployment-configured subscription billing and refund notices also
retain the platform sender. A customer's booking refund is distinct from a
platform subscription refund.

The delivery entry points are classified explicitly:

| Entry point | Sender source |
| --- | --- |
| `AppointmentEmails`, booking notices in `CalendarEmails` | Booking organizer ID |
| `PollEmails` (all eight message families) | Poll host ID, including cancellation snapshots |
| `CalendarEmails.send_calendar_invitation/2` and `send_event_update_notification/2` | Calendar event owner ID from trusted job details |
| `SendBookingPaymentRefunded` | Retained booking-payment host ID |
| Calendar sync errors and external-booking change alerts | Platform |
| Integration, account, authentication and onboarding email services | Platform |
| `SendChargeDisputeOpened`, `SendConnectAccountRestricted`, `SendConfiguredEmail` | Platform |
| Administration and operator alerts | Platform |

Jobs keep their existing required arguments and load current settings when they
run. Approval outcomes can also record that guest cancellations remain owed,
so those copies retry even after the deployment feature is disabled. Jobs carry
no SMTP credentials. Each execution snapshots a nonsecret sender
and configuration version for all its recipient copies. If the settings change
during execution, the remaining sends fail safely rather than switching
accounts. A retry resolves the new settings and preserves completed recipient
claims, so recipients already reached are not sent another copy.
Poll cancellation snapshots, calendar snapshots and retained booking payments
preserve the owning user ID after their original resource is removed. Jobs
whose required organizer no longer exists follow their domain's discard
contract; they never infer an owner from the recipient's address or retain
SMTP credentials after account deletion.

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
address. Password and app-password authentication are supported; SMTP OAuth
is not supported.

A blank password during an edit preserves the existing secret. Removing the
settings deletes the stored credentials. Account deletion cascades to the
settings record. Credentials must never appear in job arguments, browser
responses, email metadata, or application logs.

## Testing and activation

Open **Profile > Email sending**, enter the relay hostname, matching port/TLS
mode, SMTP username, password or app password, From address and display name.
Select **Test and save**. Testing runs asynchronously; the page remains
responsive, and **Use platform sender** can cancel a pending replacement test.
The username and password are never shown from storage or returned in page
markup. Leave either credential field blank when editing to preserve it.

A new identity is saved disabled. Review it and select **Enable tested identity**
to start using it for scheduling mail. Editing an enabled identity tests its
replacement before updating the active settings. Failed tests preserve the
active identity. Untested edits cannot activate the previously saved identity.
Another tab's edit, activation or deletion invalidates an older form; reload
and review the current settings before trying again.

**Use platform sender** disables the identity while retaining its encrypted
settings. **Delete saved identity** requires confirmation and deletes the
credentials. Disabling or deleting one user's identity never changes another
user's sender or the deployment's platform mailer.

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

Scheduling sends and settings tests share ten monitored connection slots per
owner, independent of configuration revision. This matches the default email
worker pool, allowing healthy group notifications to proceed concurrently.
When all slots are occupied, contention uses the worker's
bounded rate-limit snooze without counting as an account-breaker failure. The
reservation releases when the caller finishes or dies. This cap is node-local:
multiple nodes have independent reservations, and restarting the shared lock
manager forgets active reservations. Deployments needing a strict limit across
nodes or lock-manager restarts require additional coordination.

## Disablement and recovery

Set `USER_SMTP_ENABLED=false` and restart to disable all user SMTP connection
and activation operations. New scheduling executions use the platform sender.
An SMTP transaction already in progress may finish with its selected identity.
The additive table and encrypted values can remain in place across a code
rollback. Existing platform SMTP/API-provider delivery
continues to follow its deployment configuration.

Repair credentials with a new successful test, then enable the tested
revision. Retain encryption keys until the existing re-encryption sweep
confirms that no stored credentials require them. Test and connection errors
must expose sanitized categories rather than raw provider replies.

An enabled identity's authentication, TLS, DNS or delivery failures never trigger
silent platform fallback. Existing Oban retries and bounded ambiguous-timeout
handling apply. Each owner's configuration/revision has an independent circuit
breaker, even when several owners share a relay hostname. Repairing and testing
a new revision gives it a fresh breaker; the existing worker recovery/snooze
policy applies to an open circuit. Idle account breakers expire automatically.

The dashboard shows platform, saved-but-disabled, testing, enabled and
attention-required states. An account failure records a fixed, safe category
against that exact settings version. Repeated identical failures update at
most once per five minutes; successful relay acceptance or a successful retest
clears the recorded failure. This is the last observed outcome, rather than a
guarantee of inbox delivery or a strict ordering of concurrent SMTP sessions.
**Refresh status** reloads the saved settings and status; test or discard form
edits before using it. Raw relay responses and credentials never enter the
status message, and request logging filters the SMTP form including usernames.
Status writes have a short deadline and skip a saturated database pool. They
use a small, bounded budget and never reclassify an SMTP result.
Email-worker budgets include this status-write allowance for every recipient.
Calendar update jobs use their actual attendee count when it exceeds the
default booking/poll allowance; an explicit operator timeout override still applies.

## Deployment verification

Before deploying, use an operator-owned SMTP account and approved test recipients
to verify provider delivery; local acceptance tests use a scripted TLS relay.
Rehearse a queued poll notice, calendar update and booking refund with custom
SMTP enabled, then disabled, then enabled again. Each execution reads current
settings; completed recipient claims suppress another copy when the same job
retries. Confirm platform password recovery and financial alerts still work
while the custom account is broken.
