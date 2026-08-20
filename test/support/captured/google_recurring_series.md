# Google: a recurring series, captured 2026-08-20

Source: a throwaway `TYMESLOT CAPTURE PROBE` series — `FREQ=WEEKLY;COUNT=3`,
created and deleted for this capture. Redacted per `README.md`.

The five shapes below are the ones this project has repeatedly got wrong. Read
the **key counts** first: the differences between them are absences, not values
— except the last pair, which differ by a single value and nothing else.

| # | shape | call | keys | `iCalUID` | `recurringEventId` | `start`/`end` | `status` |
|---:|---|---|---:|---|---|---|---|
| 1 | series master | `get_event` | 19 | yes | **no** | yes | `confirmed` |
| 2 | confirmed instance | `list_events` (expanded) | 20 | yes | yes | yes | `confirmed` |
| 3 | cancelled occurrence | `list_events_incremental` | **6** | **no** | yes | **no** | `cancelled` |
| 4 | deleted series | `list_events_incremental` | **6** | **no** | **yes** | **no** | `cancelled` |
| 5 | deleted master | `get_event` | 19 | yes | **no** | yes | **`cancelled`** |

Rows 3 and 4 are **element-wise identical**: a deletion is a batch of
cancellations, and no field tells one entry apart from the other. Rows 1 and 5
differ in `status` alone — which is why that field, and not the fetch failing,
is what says a series is gone.

## 1. Series master — `get_event(integration, "primary", master_id)`

```elixir
%{
  "created" => "2026-08-20T18:32:02.000Z",
  "creator" => %{"email" => "organiser@example.com", "self" => true},
  "end" => %{"dateTime" => "2026-08-24T07:00:00-03:00", "timeZone" => "UTC"},
  "etag" => "\"REDACTED-ETAG\"",
  "eventType" => "default",
  "extendedProperties" => "OMITTED",
  "htmlLink" => "REDACTED",
  "iCalUID" => "t6cifbq57so03uunemf5rb6238@google.com",
  "id" => "t6cifbq57so03uunemf5rb6238",
  "kind" => "calendar#event",
  "organizer" => %{"email" => "organiser@example.com", "self" => true},
  "recurrence" => ["RRULE:FREQ=WEEKLY;COUNT=3"],
  "reminders" => %{"useDefault" => true},
  "sequence" => 0,
  "source" => "OMITTED",
  "start" => %{"dateTime" => "2026-08-24T06:00:00-03:00", "timeZone" => "UTC"},
  "status" => "confirmed",
  "summary" => "Weekly",
  "updated" => "2026-08-20T18:32:02.525Z"
}
```

`iCalUID` is `{id}@google.com` — verified, not assumed. The master carries the
`recurrence` array and **no** `recurringEventId`: it is not an occurrence of
anything.

## 2. Confirmed instance — `list_events` with `singleEvents=true`

20 keys: the master's set plus `recurringEventId` and `originalStartTime`, with
`id` as `{master}_{stamp}` and `iCalUID` still the **series** uid. Every instance
of a series shares one `iCalUID`, which is why `upsert_batch/1` collapses a
series to a single cache row.

## 3. Cancelled occurrence — `list_events_incremental`

```elixir
%{
  "etag" => "\"REDACTED-ETAG\"",
  "id" => "{master}_20260907T090000Z",
  "kind" => "calendar#event",
  "originalStartTime" => %{"dateTime" => "2026-09-07T06:00:00-03:00", "timeZone" => "UTC"},
  "recurringEventId" => "{master}",
  "status" => "cancelled"
}
```

Six keys. **No `iCalUID`** — so `raw["iCalUID"] || raw["id"]` yields the
*instance* id, which no cache row, mirror row or write-back job is keyed by.
**No `start`/`end`** — so `CalendarEvent.new/1`'s timing validation rejected it
outright, dropping the cancellation before detection and raising an admin alert
for a perfectly ordinary event.

Google reports a cancelled occurrence in **exactly one** delta and omits it from
every later one. A correction lost here is lost permanently — unlike a move,
which keeps re-appearing and so re-detects itself.

## 4. Deleted master — `list_events_incremental`

Deleting a master emits **one tombstone per occurrence**, not one for the master:

```
{master}_20260824T090000Z   status=cancelled  recurringEventId=present  iCalUID=absent
{master}_20260831T090000Z   status=cancelled  recurringEventId=present  iCalUID=absent
{master}_20260907T090000Z   status=cancelled  recurringEventId=present  iCalUID=absent
```

**3 of 3 carry `recurringEventId`.** No master-shaped entry appears at all,
because the delta sends `singleEvents=true` and Google never returns masters
under it.

This is the shape the deletion defect turns on.
`SyncGoogleCalendarWorker.withdrawn?/1` treats an event as a withdrawal only
when `recurringEventId` is **absent**, so every tombstone of a deleted series is
misrouted to the cache path and the mirror is never asked to withdraw. The
placeholder goes on blocking availability for a series that no longer exists.

Captured because that shape had been assumed rather than measured, and the
assumption was load-bearing for a proposed fix.

## 5. Deleted master — `get_event(integration, "primary", master_id)`

Deleting the series does **not** make this call fail. Captured by creating a
`FREQ=WEEKLY;COUNT=3` series, deleting it through the API, and then asking
`get_event` for the master id:

```
status     = "cancelled"
recurrence = ["RRULE:FREQ=WEEKLY;COUNT=3"]
keys = ["created","creator","end","etag","eventType","extendedProperties","htmlLink",
        "iCalUID","id","kind","organizer","recurrence","reminders","sequence","source",
        "start","status","summary","updated"]
```

**Nineteen keys — the same key set as the live master in §1**, with `recurrence`
still present and intact. The only difference anywhere in the body is `status`,
`"confirmed"` becoming `"cancelled"`.

That single field is the entire signal. `RecurringSeries.read_recurrence/3` read
only `recurrence`, found a perfectly good RRULE, and answered `{:ok, series}`,
so the engine went on rewriting a placeholder for a series the organiser had
deleted.

### Why this shape was captured

A proposed fix assumed this call answers **404** for a deleted master, and would
have keyed the withdrawal on `RecurringSeries`' `:master_fetch_failed` branch.
Measured against the live API, that branch is never reached: the fetch succeeds,
`resolve/2` returns

```elixir
{:ok, %{recurrence_rule: "RRULE:FREQ=WEEKLY;COUNT=3", all_day: false,
        start_at: ~U[2026-08-24 09:00:00Z], end_at: ~U[2026-08-24 10:00:00Z]}}
```

and a fix written against the assumption would have been a silent no-op. This is
the fifth defect in this feature traceable to a fixture describing a shape the
provider does not send, and the reason the rule at the top of `README.md` exists.

`status` is **Google's** spelling. Graph marks the same fact with a boolean
`isCancelled` and sends no `status` key at all, so this check belongs in the
Google-side reader rather than in the shared `resolve/2`.
