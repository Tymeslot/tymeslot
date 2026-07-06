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
  set at the enqueue site (`Calendar.maybe_enqueue_colour_write_back/4`) so rapid
  successive colour changes collapse onto one pending job carrying the latest
  colour, rather than racing to whichever job's PUT/PATCH lands last.
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

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "integration_id" => integration_id,
      "uid" => uid,
      "user_id" => user_id,
      "colour" => colour
    } = args

    case ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:ok, event} -> write_back(event, integration_id, user_id, colour)
      {:error, :not_found} -> {:discard, :event_not_cached}
    end
  end

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
