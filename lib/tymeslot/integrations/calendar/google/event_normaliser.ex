defmodule Tymeslot.Integrations.Calendar.Google.EventNormaliser do
  @moduledoc """
  Converts raw Google Calendar API event payloads into normalised `CalendarEvent` structs.

  Handles field mapping, datetime parsing, visibility/transparency/status inference,
  attendee normalisation, recurrence rules, and Tymeslot-origin fingerprint detection.

  ## `originalStartTime`, and why it is read at all

  Moving one occurrence of a series does not edit the series. Google leaves the
  master's RRULE untouched, adds no EXDATE, and instead returns a separate
  exception instance with its own `id`, a `recurringEventId` pointing at the
  master, and an `originalStartTime` recording where the occurrence used to be.
  The master therefore cannot reveal a move — only the instance stream can, and
  only through that one field.

  Without it a moved instance is indistinguishable from an ordinary one, since
  both carry a `recurringEventId` and a start time the rule may or may not
  predict. It is mapped to `original_start_at`, which lives on the in-flight
  struct and never reaches the cache; `CalendarEvent`'s moduledoc has the
  reasoning, and `SyncLink.MovedOccurrence` is what reads it.

  ## The cancellation tombstone, and where its uid comes from

  A cancelled occurrence arrives on the delta as six keys — `id`, `etag`,
  `kind`, `status`, `recurringEventId`, `originalStartTime` — and nothing else.
  No `start`, no `end`, and **no `iCalUID`**. It is the only report Google ever
  makes of that cancellation: the occurrence is absent from every later delta.

  That shape defeats the ordinary path twice over. The missing timing made
  `CalendarEvent.new/1` reject it, so the cancellation was dropped and an admin
  alert was raised for an event that was not malformed at all; a normal
  cancellation is not an invalid event, and it is now excepted at both points.

  The missing `iCalUID` is the subtler half. `uid` is normally
  `raw["iCalUID"] || raw["id"]`, and for a tombstone that falls through to the
  *instance* id — `{master}_{stamp}` — which nothing is keyed by: not the
  series' cache row, not the mirror row, not the write-back job the correction
  has to reach. The uid is therefore resolved from `recurringEventId` instead,
  and the cache is asked first because it already holds the answer as fact:
  every instance of the series shares one uid and collapses to one row carrying
  both that uid and the master id.

  Synthesising `"{recurringEventId}@google.com"` is the fallback, not the
  primary, and the ordering is the whole point. The convention is real and
  relied on elsewhere (`calendar_sync_mirror_queries.ex`, `provider_event_id.ex`,
  `event_mapper.ex`), but it holds only for a series Google minted. An event
  imported into Google keeps the foreign UID it arrived with, and synthesis
  would then confidently produce a uid no row carries — a wrong answer where
  the lookup would have given the right one. The lookup fails closed and the
  synthesis guesses, so the guess only runs when there is nothing to fail
  closed against: a series whose master has not been cached yet, where a
  Google-minted id is also the overwhelmingly likelier case.
  """

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Timezones

  @spec normalise_events(list(map()), map()) :: {:ok, list(CalendarEvent.t())}
  def normalise_events(raw_events, context) do
    events =
      raw_events
      |> Enum.reduce([], fn raw, acc ->
        case build_calendar_event(raw, context) do
          {:ok, event} ->
            [event | acc]

          {:error, reason} ->
            skip(raw, reason, context)
            acc
        end
      end)
      |> Enum.reverse()

    {:ok, events}
  end

  # A tombstone is built from a different set of facts than an event, so it is
  # assembled separately rather than by threading exceptions through the event
  # path. It has no timing to parse, no timezone to read, no colour, no
  # attendees — every one of those mappings would be reading keys the payload
  # does not have — and its uid comes from the series rather than from itself.
  defp build_calendar_event(raw, context) do
    if tombstone?(raw) do
      build_tombstone(raw, context)
    else
      build_event(raw, context)
    end
  end

  # The shape, stated as the delta states it: cancelled, naming a master, and
  # carrying no `start`. The absent start is what separates a tombstone from a
  # cancelled occurrence Google described in full — the latter is a complete
  # event whose status happens to be cancelled, is cached as one, and is
  # detected by `MovedOccurrence` through the ordinary path.
  defp tombstone?(%{"status" => "cancelled"} = raw),
    do: is_binary(raw["recurringEventId"]) and not Map.has_key?(raw, "start")

  defp tombstone?(_raw), do: false

  defp build_tombstone(raw, context) do
    CalendarEvent.new(%{
      uid: series_uid(raw, context),
      provider: :google,
      calendar_integration_id: context.calendar_integration_id,
      provider_calendar_id: context.provider_calendar_id,
      provider_event_id: raw["id"],
      recurring_event_id: raw["recurringEventId"],
      synced_at: context.synced_at,
      status: :cancelled,
      all_day: false,
      original_start_at: parse_original_start(raw["originalStartTime"]),
      etag: raw["etag"],
      tombstone?: true
    })
  end

  # Cache first, Google's convention second. The moduledoc has the reasoning:
  # the lookup fails closed on a series that was cached under a foreign UID,
  # where synthesis would answer confidently and wrongly.
  defp series_uid(raw, context) do
    master = raw["recurringEventId"]

    case ProviderCalendarEventQueries.series_uid_for_master(
           context.calendar_integration_id,
           master
         ) do
      {:ok, uid} ->
        uid

      {:error, :not_found} ->
        Logger.info("Synthesising a series uid for a cancellation tombstone",
          recurring_event_id: master,
          event_id: raw["id"],
          calendar_integration_id: context.calendar_integration_id
        )

        "#{master}@google.com"
    end
  end

  # A tombstone rejected by `CalendarEvent.new/1` is still not an admin alert.
  # It reached here because the payload was cancelled, named a series and
  # carried no start — a shape Google produces — so the failure is a missing
  # `originalStartTime`, which is a provider oddity worth a log and not an
  # operator page. Everything else keeps the alert it always had.
  defp skip(raw, reason, context) do
    Logger.warning("Skipping invalid Google calendar event",
      reason: reason,
      event_id: raw["id"],
      calendar_integration_id: context.calendar_integration_id
    )

    unless tombstone?(raw) do
      AdminAlerts.send_alert(:invalid_calendar_event, %{
        provider: :google,
        event_id: raw["id"],
        reason: reason,
        calendar_integration_id: context.calendar_integration_id
      })
    end

    :ok
  end

  defp build_event(raw, context) do
    attrs =
      %{
        uid: raw["iCalUID"] || raw["id"],
        provider: :google,
        calendar_integration_id: context.calendar_integration_id,
        provider_calendar_id: context.provider_calendar_id,
        provider_event_id: raw["id"],
        recurring_event_id: raw["recurringEventId"],
        synced_at: context.synced_at,
        summary: raw["summary"],
        description: raw["description"],
        location: raw["location"],
        visibility: map_visibility(raw["visibility"]),
        transparency: map_transparency(raw["transparency"]),
        status: map_status(raw["status"]),
        organiser: map_organiser(raw["organizer"]),
        attendees: map_attendees(raw["attendees"]),
        reminders: map_reminders(raw["reminders"]),
        colour: EventColour.from_google_color_id(raw["colorId"]),
        etag: raw["etag"],
        provider_updated_at: parse_provider_updated_at(raw["updated"], raw["id"], context),
        original_start_at: parse_original_start(raw["originalStartTime"]),
        recurrence_rule: map_recurrence_rule(raw["recurrence"]),
        provider_metadata: Map.put(raw, "recurringEventId", raw["recurringEventId"]),
        created_by_tymeslot:
          get_in(raw, ["extendedProperties", "private", "createdBy"]) == "tymeslot"
      }
      |> Map.merge(parse_timing(raw))
      |> maybe_put_timezone(raw)

    CalendarEvent.new(attrs)
  end

  defp map_visibility("public"), do: :public
  defp map_visibility("private"), do: :private
  defp map_visibility("confidential"), do: :confidential
  defp map_visibility(_other), do: nil

  defp map_transparency("transparent"), do: :transparent
  defp map_transparency(_other), do: :opaque

  defp map_status("confirmed"), do: :confirmed
  defp map_status("tentative"), do: :tentative
  defp map_status("cancelled"), do: :cancelled
  defp map_status(_other), do: :confirmed

  defp map_organiser(nil), do: nil

  defp map_organiser(organiser) do
    %{email: organiser["email"], display_name: organiser["displayName"]}
  end

  defp map_attendees(nil), do: []

  defp map_attendees(attendees) when is_list(attendees) do
    Enum.map(attendees, fn a ->
      %{
        email: a["email"],
        display_name: a["displayName"],
        response_status: map_response_status(a["responseStatus"]),
        optional: a["optional"] || false
      }
    end)
  end

  defp map_response_status("accepted"), do: :accepted
  defp map_response_status("declined"), do: :declined
  defp map_response_status("tentative"), do: :tentative
  defp map_response_status("needsAction"), do: :needs_action
  defp map_response_status(_other), do: :needs_action

  defp map_reminders(%{"overrides" => overrides}) when is_list(overrides) do
    Enum.map(overrides, fn r ->
      %{method: map_reminder_method(r["method"]), minutes_before: r["minutes"]}
    end)
  end

  defp map_reminders(_other), do: []

  defp map_reminder_method("email"), do: :email
  defp map_reminder_method("popup"), do: :popup
  defp map_reminder_method("sms"), do: :sms
  defp map_reminder_method(_other), do: :popup

  defp map_recurrence_rule([first | _rest]), do: first
  defp map_recurrence_rule(_other), do: nil

  defp parse_timing(%{"start" => %{"date" => start_date}, "end" => %{"date" => end_date}}) do
    with {:ok, sd} <- Date.from_iso8601(start_date),
         {:ok, ed} <- Date.from_iso8601(end_date) do
      %{all_day: true, start_date: sd, end_date: ed}
    else
      _error -> %{all_day: true, start_date: nil, end_date: nil}
    end
  end

  defp parse_timing(%{
         "start" => %{"dateTime" => start_dt},
         "end" => %{"dateTime" => end_dt}
       }) do
    with {:ok, s, _offset} <- DateTime.from_iso8601(start_dt),
         {:ok, e, _offset} <- DateTime.from_iso8601(end_dt) do
      %{
        all_day: false,
        start_at: DateTime.shift_zone!(s, "Etc/UTC"),
        end_at: DateTime.shift_zone!(e, "Etc/UTC")
      }
    else
      _error -> %{all_day: false, start_at: nil, end_at: nil}
    end
  end

  defp parse_timing(_other), do: %{all_day: false, start_at: nil, end_at: nil}

  # `parse_timing/1` above matches the start/end *pair* and answers with the
  # whole timing map, so it cannot be reused for a lone value — hence this
  # smaller twin. It shares that function's two rules, and for the same reasons:
  # the `dateTime` branch shifts to UTC so the result is directly comparable
  # with `start_at`, which is stored that way, and a `date` stays a `Date` so an
  # all-day move is comparable with `start_date`.
  #
  # Every unparseable shape answers `nil` rather than raising. This runs inside
  # a sync job over a whole calendar, and a marker that is strictly an
  # observation must never be the reason an event — or the batch around it — is
  # lost. Nil reads as "not known to have moved", which is the honest reading of
  # a value that could not be understood.
  defp parse_original_start(%{"dateTime" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.shift_zone!(at, "Etc/UTC")
      _error -> nil
    end
  end

  defp parse_original_start(%{"date" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp parse_original_start(_absent), do: nil

  # Google's own account of when it last wrote the event, RFC3339 with
  # milliseconds. Every staleness comparison downstream is written against it —
  # `SyncLinkReconcileWorker.stale?/2`, `ConflictLog`'s
  # `compared_by => "provider_updated_at"` path, the baseline `Engine` stamps as
  # a mapping's `source_updated_at` — and all of them read `nil` as "cannot
  # tell" and stand down. Dropping the field therefore does not fail loudly; it
  # switches those checks off and looks exactly like a calendar that never
  # changes, which is how it went unnoticed until the column was found empty
  # across every cached row.
  #
  # Shifted to UTC so it is directly comparable with the stored column and with
  # a mapping's baseline, both `:utc_datetime_usec`.
  #
  # An absent value is ordinary — a provider need not report one, and `nil` is
  # the documented reading — so it passes quietly. A value that is *present and
  # unreadable* is not ordinary: it means Google's format moved, or something
  # upstream mangled it, and every one of those checks is silently disarmed for
  # that event. That is worth a log line naming the value, since the symptom on
  # its own is indistinguishable from a calendar sitting still. It is still only
  # a log: this runs inside a sync over a whole calendar, and a bookkeeping
  # marker must never be the reason an event, or the batch around it, is lost.
  defp parse_provider_updated_at(nil, _event_id, _context), do: nil

  defp parse_provider_updated_at(value, event_id, context) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        DateTime.shift_zone!(at, "Etc/UTC")

      {:error, reason} ->
        log_unparseable_update(value, reason, event_id, context)
        nil
    end
  end

  defp parse_provider_updated_at(value, event_id, context) do
    log_unparseable_update(value, :not_a_string, event_id, context)
    nil
  end

  defp log_unparseable_update(value, reason, event_id, context) do
    Logger.warning("Ignoring unparseable Google event `updated` timestamp",
      value: inspect(value),
      reason: reason,
      event_id: event_id,
      calendar_integration_id: context.calendar_integration_id
    )
  end

  defp maybe_put_timezone(attrs, %{"start" => %{"timeZone" => tz}}) do
    case Timezones.sanitize(tz) do
      nil -> attrs
      clean -> Map.put(attrs, :timezone, clean)
    end
  end

  defp maybe_put_timezone(attrs, _raw), do: attrs
end
