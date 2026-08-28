# Booking API

Create bookings on an organiser's behalf from another system — a CRM booking a
slot agreed on a call, a form on your own site, an automation platform.

Tymeslot already tells you what happened through webhooks. This is the other
direction: it lets you put a meeting in the organiser's diary without anyone
retyping the attendee's details. The attendee is invited exactly as if they had
booked themselves, with their own cancel and reschedule links.

There is one endpoint. Everything else about the booking — calendar sync, the
invitation email, the video room, the `meeting_created` webhook — happens on its
own, as it does for any other booking.

## Enabling it

Dashboard → **Automation** → **Webhooks** tab → **Booking API** → *Enable
booking API*.

That generates a secret token for your account. Anyone holding it can put
meetings in your diary, so treat it like a password: keep it in your
integration's secret store, not in a URL, a repository or a browser. *Regenerate
token* invalidates the previous one immediately; *Disable booking API* closes
the endpoint for your account without affecting anyone else on the instance.

## Creating a booking

```
POST /api/v1/bookings
Authorization: Bearer <your token>
Content-Type: application/json
Idempotency-Key: <your own key>   (optional, strongly recommended)
```

```json
{
  "attendee_name": "Robin Vale",
  "attendee_email": "robin@example.com",
  "start_time": "2026-09-14T09:30:00Z",
  "duration_minutes": 30,
  "title": "Discovery call"
}
```

```json
{
  "meeting": {
    "uid": "6f1c2f7a-2f28-4a5f-9a0c-8b2b4a2f9e11",
    "status": "confirmed",
    "title": "Discovery call",
    "start_time": "2026-09-14T09:30:00Z",
    "end_time": "2026-09-14T10:00:00Z",
    "duration_minutes": 30,
    "attendee_name": "Robin Vale",
    "attendee_email": "robin@example.com",
    "attendee_timezone": "Etc/UTC",
    "view_url": "https://example.com/host/meeting/6f1c2f7a-…",
    "reschedule_url": "https://example.com/host/meeting/6f1c2f7a-…/reschedule",
    "cancel_url": "https://example.com/host/meeting/6f1c2f7a-…/cancel",
    "meeting_url": null
  }
}
```

`201` means the meeting was created. Store `uid` — it is how you recognise this
booking in the webhooks that follow — along with the three URLs, which are what
you show the attendee in your own system.

### Request fields

| Field | Required | Notes |
|---|---|---|
| `attendee_name` | yes | Up to 255 characters. |
| `attendee_email` | yes | Where the invitation goes. Cannot be the organiser's own address. |
| `start_time` | yes | ISO 8601 **with a UTC offset** — `2026-09-14T09:30:00Z` or `2026-09-14T11:30:00+02:00`. A timestamp without one is refused rather than assumed to be UTC. |
| `end_time` | one of these three | ISO 8601 with an offset, after `start_time`. |
| `duration_minutes` | one of these three | 1–1440. Cannot be combined with `end_time`. |
| `meeting_type` | one of these three | The slug of one of the organiser's meeting types. Supplies the duration, the title and the video room. |
| `title` | unless `meeting_type` is given | What the meeting is called. Wins over the meeting type's name when both are given. |
| `attendee_timezone` | no | IANA name, e.g. `Europe/Berlin`. Defaults to `Etc/UTC`. Sets the time zone the attendee's invitation and pages are rendered in. |
| `guest_emails` | no | Up to 20 additional addresses, copied on the invitation. |
| `force` | no | `true` skips the availability checks below. Default `false`. |

Fields the endpoint does not model are ignored, so you can leave your own
correlation keys in the body without them reaching anything.

### Naming a meeting type

Passing `meeting_type` books against one of the organiser's configured types
rather than an ad-hoc slot:

```json
{
  "attendee_name": "Robin Vale",
  "attendee_email": "robin@example.com",
  "start_time": "2026-09-14T09:30:00Z",
  "meeting_type": "discovery-call"
}
```

The duration, the title and the video-room provider come from the type, so the
booking is indistinguishable from one the attendee made themselves. Paid meeting
types are refused: confirming one outside the payment flow would give away a
meeting nobody paid for.

## Availability

By default the endpoint respects the organiser's diary. It applies:

- their **notice period and booking horizon**, and
- a **fresh read of their connected calendars**, so a slot filled minutes ago
  since the last sync is still seen.

A slot that fails either is refused with `409 slot_unavailable`, and one that
collides with a meeting Tymeslot already holds with `409 time_conflict`.

`"force": true` waives the first two, for the case the endpoint exists to serve:
the organiser has agreed the slot with the attendee directly and wants it booked
regardless. The check against Tymeslot's own meetings always runs — `force` will
not double-book the organiser against themselves.

The endpoint does **not** apply the organiser's weekly working hours. A booking
made on someone's behalf is often deliberately outside them.

If the organiser's calendar provider cannot be reached, the booking proceeds and
the failure is logged. Refusing would make a provider outage look like a full
diary.

## Retrying safely

A network timeout leaves you unable to tell whether the booking happened. Send
an `Idempotency-Key` header — any string of your own, up to 255 characters, that
identifies this booking attempt — and the retry is safe:

- first request → `201`, meeting created;
- retry with the same key → `200`, carrying the same meeting;
- a different key → a new booking.

Keys are scoped to the organiser and are held for as long as the meeting exists.
A request that was *refused* frees its key immediately, so you can correct the
body and retry under the same one.

Without a key, a retried request books the attendee twice — unless the two
bookings collide, in which case the second is refused as a `time_conflict`.

## Webhooks and the echo

A booking created here raises `meeting_created` exactly as a booking made from
the dashboard calendar does. If the system calling this endpoint also subscribes
to that webhook, it will receive an event describing the booking it has just
made. Match on the `uid` you stored from the `201` response and skip your own
writes.

One exception on `main` today, inherited from the path the dashboard calendar
already uses: when the meeting type provisions a video room, the notifications
are deferred to the room-creation job, which sends the emails but does not raise
`meeting_created`. A booking naming such a meeting type therefore produces no
webhook. That is a defect rather than a design, and #87 fixes it — once that
lands, this paragraph goes with it.

## Errors

Every failure carries a machine-readable `code`:

```json
{
  "error": {
    "code": "invalid_params",
    "message": "The request body was not accepted.",
    "violations": [
      { "field": "attendee_email", "message": "Email format is invalid" },
      { "field": "start_time", "message": "must carry a UTC offset, e.g. 2026-09-01T09:00:00Z" }
    ]
  }
}
```

| Status | Code | Meaning |
|---|---|---|
| 400 | `invalid_params` | The body was rejected. `violations` lists **every** offending field, so one round trip is enough to fix them all. |
| 401 | `unauthorized` | No token, a scheme other than `Bearer`, or a token that is not live. Deliberately says nothing more. |
| 403 | `upgrade_required` / `forbidden` | The organiser's plan or instance does not include the booking API. |
| 409 | `slot_unavailable` | The organiser is not free then. Send `force: true` to book anyway. |
| 409 | `time_conflict` | The organiser already has a Tymeslot meeting at that time. |
| 409 | `in_progress` | An earlier request with the same idempotency key has not finished. Retry. |
| 422 | `meeting_type_not_found` | No active meeting type of the organiser's has that slug. |
| 422 | `meeting_type_requires_payment` | That type is paid and must go through checkout. |
| 422 | `booking_rejected` | The booking was refused for a reason carried in `message` — for instance, the attendee address is the organiser's own. |
| 429 | `rate_limited` | Too many requests. Retry shortly. |

## Rate limits

Two budgets, both over a rolling minute: **120 requests per client IP** and
**60 per organiser**. The IP budget is spent before the token is looked up, so
an unauthenticated flood cannot exhaust a legitimate caller's allowance.

## Video rooms

When the meeting type provisions a video room, the room is created by a
background job. `meeting_url` is therefore `null` in the response, and the link
reaches the attendee with their invitation.

## Example

```bash
curl -sS -X POST https://example.com/api/v1/bookings \
  -H "Authorization: Bearer $TYMESLOT_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: crm-opportunity-4182" \
  -d '{
        "attendee_name": "Robin Vale",
        "attendee_email": "robin@example.com",
        "start_time": "2026-09-14T09:30:00Z",
        "meeting_type": "discovery-call"
      }'
```
