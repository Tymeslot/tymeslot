# Captured provider payloads

Raw provider responses, transcribed from live API calls, with account-identifying
fields redacted at the point of capture.

These exist because four consecutive fixes to cross-calendar mirroring shipped
green and failed on a real calendar. Every one had a fixture describing a shape
the provider does not send:

- every `create_event` mock returned `%{provider_event_id: ...}`, which no OAuth
  provider produces — the id lands under `uid`;
- a Google event-id test asserted standard base32, the alphabet of the
  implementation rather than the one Google accepts;
- a cancelled-occurrence fixture carried `iCalUID` on a delta tombstone, which
  the delta omits. That one cost four rounds: the tests supplied the uid the
  production code could not derive, so each fix passed and each failed live.

A fixture invented from a plausible reading of the API docs is worse than no
fixture, because it makes a broken pipeline look tested.

## The rule

**A fixture for a provider payload is transcribed from a captured response, and
its doc names the API call it came from.**

Naming the call is not ceremony. The cancellation fixture's doc claimed it was
"measured on the live calendar" — true of `get_event`, false of
`list_events_incremental`, and those two disagree about `iCalUID`. A provenance
line that names the call would have caught it; one that says "measured" did not.

## What is redacted, and what is not

Redaction runs on the live node before anything is printed, so unredacted bodies
never reach a terminal or a file.

Removed: e-mail addresses (organiser, creator, attendees), display names,
`htmlLink` (embeds the calendar id), free-text `summary`, `description` and
`location`, `etag` values, and the `source` / `extendedProperties` blocks that
can carry account-specific values.

Kept verbatim: every structural field the normaliser branches on — `id`,
`iCalUID`, `kind`, `status`, `recurringEventId`, `originalStartTime`, `start`,
`end`, `recurrence`, `sequence`, `eventType`, and the key set itself. The key
set is the point: what a payload *omits* is what has broken this code every
time.

Ids are real but disposable — they belong to throwaway probe series created for
the capture and deleted immediately after. They identify nothing.

## Re-capturing

Capture needs live provider credentials, so it cannot run in CI. That is why
these files are the durable artefact: re-capturing is manual and occasional, and
a fixture drifting from reality shows up as a diff against a dated record rather
than as a map nobody thought to question.

The delta capture races the webhook sync, which consumes the sync token first
and leaves the delta empty. Pause the `:calendar_events` queue for the capture
window, resume in an `after` block, and do not persist the token — the resumed
sync then replays the same delta and processes the change normally.

**An empty delta is a lost race, not proof of absence.** Treat a zero-length
result as a failed capture; reporting it as "nothing to see" is how two
verification runs in this project reported success having examined nothing.
