defmodule Tymeslot.Workers.ColourWriteBackWorker do
  @moduledoc """
  Best-effort push of a per-event colour to the host calendar via a
  colour-only patch (Google `events.patch` sending just `colorId` / CalDAV
  patching only the `COLOR` property on the event's last-synced `raw_ical`).
  No other field is ever sent, so recurrence, attendees, alarms, and
  conference data already on the host event are never touched.

  Outlook has no per-event colour concept, so those jobs are discarded. Read-only
  calendars and transient failures surface as errors and are retried by Oban; the
  durable override remains the display source regardless of write-back outcome.
  Only *set* enqueues a job — clearing a colour leaves the host untouched.

  `unique` is keyed on `[:integration_id, :uid, :user_id]` with `replace: [:args]`
  set at the enqueue site (`ColourWriteBack.enqueue/4`, called from
  `Calendar.set_event_colour/3`) so rapid successive colour changes collapse onto
  one pending job carrying the latest colour, rather than racing to whichever
  job's PUT/PATCH lands last.

  A CalDAV event created from the dashboard grid is cached with `raw_ical` NULL
  by design, for the first read to fill, so a colour set before that sync has no
  document to patch. That is an expected, recoverable state rather than a
  failure, so the job snoozes until a sync has populated the column instead of
  spending its attempts against it.
  """
  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 3,
    priority: 2,
    unique: [
      keys: [:integration_id, :uid, :user_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  # Comfortably longer than the slowest CalDAV sync cadence, the 3600s Tier 3
  # interval in `FallbackSyncSweepWorker`, so each snooze lands after a sync
  # that could have filled `raw_ical` rather than racing one.
  @raw_ical_snooze_seconds 5_400

  # Oban preserves `max_attempts` across a snooze, so nothing else bounds this
  # loop: an integration deleted or left broken before its next sync would
  # snooze forever. Sixteen snoozes is a day, past the 24h forced full fetch,
  # after which the colour is only ever going to be Tymeslot's own.
  @max_raw_ical_snoozes 16

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, meta: meta}) do
    %{
      "integration_id" => integration_id,
      "uid" => uid,
      "user_id" => user_id,
      "colour" => colour
    } = args

    case ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:ok, event} ->
        event
        |> write_back(integration_id, user_id, colour)
        |> handle_unsynced_document(meta)

      {:error, :not_found} ->
        {:discard, :event_not_cached}
    end
  end

  # `Events.update_event_colour/5` names this outcome for exactly this case:
  # there is no cached document to patch yet, and a sync is what fills it. It
  # is a snooze rather than an error so the attempts are not spent against a
  # column only a sync can fill, and rather than a discard so the eventual
  # write survives — `unique` includes `:scheduled` and the enqueue site passes
  # `replace: [:args]`, so a later colour change updates this pending job in
  # place.
  defp handle_unsynced_document({:error, :raw_ical_unavailable}, meta) do
    if Map.get(meta, "snoozed", 0) < @max_raw_ical_snoozes do
      {:snooze, @raw_ical_snooze_seconds}
    else
      {:discard, :raw_ical_never_synced}
    end
  end

  defp handle_unsynced_document(result, _meta), do: result

  # Microsoft Graph exposes no per-event colour, so there is nothing to push.
  defp write_back(%{provider: "outlook"}, _integration_id, _user_id, _colour),
    do: {:discard, :provider_has_no_event_colour}

  defp write_back(event, integration_id, user_id, colour) do
    event_data = colour_only_event_data(event, colour)

    CalendarEvents.update_event(event.uid, event_data, {integration_id, user_id})
  end

  # Colour-only payload: just enough for the provider path to identify the
  # event and patch its colour (Google `colorId` via PATCH, CalDAV `COLOR` via
  # a patched copy of `raw_ical`). Deliberately excludes summary/timing/
  # description/location — a full-field payload would only be safe to send
  # via a full REPLACE, which is exactly what silently wiped recurrence,
  # attendees, alarms, and conference data before this fix.
  #
  # `etag` is the cached ETag for the event. The CalDAV path uses it as the
  # `If-Match` precondition on the colour PUT so that, if the host event has
  # been edited on the server since our last sync, the PUT 412s and Oban
  # retries against fresh data rather than reverting the edit to our stale
  # `raw_ical` snapshot. Ignored by providers without ETag semantics (Google).
  defp colour_only_event_data(event, colour) do
    %{
      colour_only: true,
      colour: colour,
      provider_event_id: event.provider_event_id,
      raw_ical: event.raw_ical,
      etag: event.etag
    }
  end
end
