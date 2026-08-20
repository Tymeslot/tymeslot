defmodule Tymeslot.GoogleDeltaFixtures do
  @moduledoc """
  The raw entries `GoogleCalendarApi.list_events_incremental/1` hands back for
  occurrences of a recurring series, before `Google.EventNormaliser` touches
  them — string keys, exactly as captured off the live API.

  They live in their own module because a confirmed occurrence and a cancelled
  one are **different payloads**, and keeping them together is what makes that
  visible. There is deliberately no option that turns one into the other.

  Every constructor here is transcribed from a captured response recorded in
  `test/support/captured/google_recurring_series.md`, which names the API call
  each shape came from. That provenance is the point: the same series read
  through `get_event` and through `list_events_incremental` disagrees about
  whether `iCalUID` is present, and a fixture that does not say which call it
  describes cannot be checked.

  ## The family regrew once more, in the fixture claiming to have been measured

  `google_delta_occurrence/4` took a `status:` option and stamped
  `"iCalUID" => "{master}@google.com"` either way, so a caller asking for a
  cancelled occurrence got a field Google's cancellation delta does not send.
  The "measured on the live calendar" claim described a `get_event` response —
  which does carry `iCalUID` — not a delta tombstone, which does not.

  It cost four consecutive fixes, each green and each failing live, because the
  tests supplied the uid the code could not derive. A cancellation now has its
  own constructor, `google_delta_cancellation/2`, transcribed from the captured
  body; no option here turns a confirmed occurrence into a cancelled one.
  """

  @doc """
  One raw Google delta entry for a **confirmed** occurrence of a recurring
  series: the shape `GoogleCalendarApi.list_events_incremental/1` hands back
  before `Google.EventNormaliser` touches it — string keys, `recurringEventId`
  naming the master, the master's `iCalUID`, and an `originalStartTime`
  differing from `start` exactly when the occurrence has moved.

  A cancellation is **not** produced by passing `status: "cancelled"` here, and
  cannot be: it is a different payload, not this one with a field changed. Use
  `google_delta_cancellation/2`.

  The `status:` option stays, and is not a way to build a tombstone. Google also
  emits a **fully-described** cancelled occurrence — 21 keys, with `iCalUID`,
  `start` and `end` — when the occurrence is cancelled but still described. That
  one must be cached with its timing intact, and this constructor is how a test
  says so.

  What it cannot build is the six-key delta tombstone, because that shape is
  defined by what it omits. `status: "cancelled"` here yields a cancelled
  occurrence that still carries `iCalUID` and timing, which is a real payload —
  just not the one `google_delta_cancellation/2` describes.
  """
  @spec google_delta_occurrence(String.t(), String.t(), String.t(), keyword()) :: map()
  def google_delta_occurrence(master_id, stamp, start_iso, opts \\ []) do
    at = fn iso -> %{"dateTime" => iso, "timeZone" => "UTC"} end

    %{
      "id" => "#{master_id}_#{stamp}",
      "iCalUID" => "#{master_id}@google.com",
      "recurringEventId" => master_id,
      "status" => Keyword.get(opts, :status, "confirmed"),
      "summary" => Keyword.get(opts, :summary, "Weekly"),
      "start" => at.(start_iso),
      "end" => at.(start_iso),
      "originalStartTime" => at.(Keyword.get(opts, :original_start, start_iso))
    }
  end

  @doc """
  The delta entry Google sends for a **cancelled** occurrence of a recurring
  series, and the only report of that cancellation it ever makes — the
  occurrence is absent from every later delta.

  Six keys, and the two absences matter more than anything present:

  - **no `start` or `end`.** A tombstone states that an occurrence is gone; it
    does not describe an event. This is what `CalendarEvent.new/1` rejected,
    dropping the cancellation and raising an admin alert for it.
  - **no `iCalUID`.** So `uid: raw["iCalUID"] || raw["id"]` falls through to
    the *instance* id, which no cache row, mirror row or write-back job is
    keyed by. The series uid has to be recovered from `recurringEventId`.

  Both absences are why this is a separate constructor rather than an option on
  `google_delta_occurrence/4`. The shape is the captured body, key for key.
  """
  @spec google_delta_cancellation(String.t(), String.t()) :: map()
  def google_delta_cancellation(master_id, original_start_iso) do
    %{
      "etag" => "\"3574453837861694\"",
      "id" => "#{master_id}_#{stamp_of(original_start_iso)}",
      "kind" => "calendar#event",
      "originalStartTime" => %{"dateTime" => original_start_iso, "timeZone" => "UTC"},
      "recurringEventId" => master_id,
      "status" => "cancelled"
    }
  end

  @doc """
  The delta entries Google sends when a whole recurring **series** is deleted.

  One tombstone **per occurrence**, never one for the master: the delta is
  fetched with `singleEvents=true` (`google_calendar_api.ex:324`), under which
  Google does not return masters at all. Captured from a three-occurrence
  series, which produced three entries, all carrying `recurringEventId` and none
  carrying `iCalUID`.

  That is the shape `SyncGoogleCalendarWorker.withdrawn?/1` misroutes. It treats
  an event as a withdrawal only when `recurringEventId` is **absent**, so every
  tombstone of a deleted series is classified as an ordinary change, the mirror
  is never asked to withdraw, and the placeholder goes on blocking availability
  for a series that no longer exists.

  A deleted master and a cancelled occurrence are **the same six keys**. What
  separates them is not the payload but the batch: a deletion cancels every
  occurrence, a cancellation cancels one. Any predicate that tries to tell them
  apart from a single entry is reading something that is not there.
  """
  @spec google_delta_series_deletion(String.t(), [String.t()]) :: [map()]
  def google_delta_series_deletion(master_id, occurrence_isos) do
    Enum.map(occurrence_isos, &google_delta_cancellation(master_id, &1))
  end

  @doc """
  The `get_event` response for a series **master** — 19 keys.

  Carries `recurrence` and, unlike every occurrence, **no**
  `recurringEventId`: a master is not an occurrence of anything. Its `iCalUID`
  is `{id}@google.com`, verified against the live API rather than assumed, which
  is what licenses synthesising a series uid from a `recurringEventId` when a
  tombstone omits it.

  Use this where a test needs the master itself. It is not what a delta returns:
  a delta with `singleEvents=true` never contains one.
  """
  @spec google_series_master(String.t(), String.t(), keyword()) :: map()
  def google_series_master(master_id, start_iso, opts \\ []) do
    at = fn iso -> %{"dateTime" => iso, "timeZone" => "UTC"} end
    rule = Keyword.get(opts, :recurrence_rule, "RRULE:FREQ=WEEKLY;COUNT=3")

    %{
      "created" => "2026-08-20T18:32:02.000Z",
      "creator" => %{"email" => "organiser@example.com", "self" => true},
      "end" => at.(Keyword.get(opts, :end_iso, start_iso)),
      "etag" => "\"REDACTED-ETAG\"",
      "eventType" => "default",
      "iCalUID" => "#{master_id}@google.com",
      "id" => master_id,
      "kind" => "calendar#event",
      "organizer" => %{"email" => "organiser@example.com", "self" => true},
      "recurrence" => [rule],
      "reminders" => %{"useDefault" => true},
      "sequence" => 0,
      "start" => at.(start_iso),
      "status" => Keyword.get(opts, :status, "confirmed"),
      "summary" => "Weekly",
      "updated" => "2026-08-20T18:32:02.525Z"
    }
  end

  @doc """
  The `get_event` response for the master of a series that has been **deleted**.

  Deleting a series does not make this call fail, and that assumption is what
  made the deletion defect invisible. Captured by creating a
  `FREQ=WEEKLY;COUNT=3` series, deleting it, and asking `get_event` for the
  master: the body comes back with the **same 19 keys as a live master** and its
  `recurrence` array intact. The only field that changes anywhere is `status`,
  `"confirmed"` becoming `"cancelled"`.

  So a reader that looks at `recurrence` alone — which is what
  `RecurringSeries.read_recurrence/3` was — finds a perfectly good RRULE and
  answers `{:ok, series}` for a series the organiser has deleted. The engine
  then rewrites the placeholder instead of withdrawing it, and the busy block
  outlives the series indefinitely.

  A proposed fix keyed the withdrawal on `:master_fetch_failed`, the branch a
  404 would take. Measured live, that branch is never reached, and the fix would
  have been a silent no-op. `status` is the discriminator that actually fires.

  This is deliberately `google_series_master/3` with one option rather than a
  hand-written body: the point of the shape is that it is the live master's key
  set unchanged, and building it any other way would let the two drift.
  """
  @spec google_deleted_series_master(String.t(), String.t(), keyword()) :: map()
  def google_deleted_series_master(master_id, start_iso, opts \\ []) do
    google_series_master(master_id, start_iso, Keyword.put(opts, :status, "cancelled"))
  end

  # Google names an instance `{master}_{basic ISO 8601 UTC}`.
  defp stamp_of(iso) do
    {:ok, at, _offset} = DateTime.from_iso8601(iso)

    at
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
