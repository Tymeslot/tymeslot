defmodule Tymeslot.Integrations.Calendar.Outlook.EventNormaliser do
  @moduledoc """
  Converts raw Microsoft Graph API event payloads into normalised `CalendarEvent` structs.

  Handles field mapping, datetime parsing, visibility/transparency/status inference,
  attendee normalisation, recurrence rules, and Tymeslot-origin fingerprint detection.
  """

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverter
  alias Tymeslot.Timezones

  @outlook_tymeslot_property_id "String {00020329-0000-0000-C000-000000000046} Name createdBy"

  @spec normalise_events(list(map()), map()) :: {:ok, list(CalendarEvent.t())}
  def normalise_events(raw_events, context) do
    events =
      raw_events
      |> Enum.reduce([], fn raw, acc ->
        case build_calendar_event(raw, context) do
          {:ok, event} ->
            [event | acc]

          {:error, reason} ->
            Logger.warning("Skipping invalid Outlook calendar event",
              reason: reason,
              event_id: raw["id"],
              calendar_integration_id: context.calendar_integration_id
            )

            AdminAlerts.send_alert(:invalid_calendar_event, %{
              provider: :outlook,
              event_id: raw["id"],
              reason: reason,
              calendar_integration_id: context.calendar_integration_id
            })

            acc
        end
      end)
      |> Enum.reverse()

    {:ok, events}
  end

  defp build_calendar_event(raw, context) do
    attrs =
      %{
        uid: raw["iCalUId"] || raw["id"],
        provider: :outlook,
        calendar_integration_id: context.calendar_integration_id,
        provider_calendar_id: context.provider_calendar_id,
        provider_event_id: raw["id"],
        recurring_event_id: raw["seriesMasterId"],
        synced_at: context.synced_at,
        summary: raw["subject"],
        description: get_in(raw, ["body", "content"]),
        location: get_in(raw, ["location", "displayName"]),
        visibility: map_visibility(raw["sensitivity"]),
        transparency: map_transparency(raw["showAs"]),
        status: map_status(raw),
        organiser: map_organiser(raw["organizer"]),
        attendees: map_attendees(raw["attendees"]),
        reminders: map_reminders(raw["reminderMinutesBeforeStart"]),
        recurrence_rule: map_recurrence_rule(raw["recurrence"]),
        provider_metadata: Map.put(raw, "seriesMasterId", raw["seriesMasterId"]),
        created_by_tymeslot: tymeslot_origin?(raw)
      }
      |> Map.merge(parse_timing(raw))
      |> maybe_put_timezone(raw)

    CalendarEvent.new(attrs)
  end

  defp tymeslot_origin?(%{"singleValueExtendedProperties" => props})
       when is_list(props) do
    Enum.any?(props, fn
      %{"id" => @outlook_tymeslot_property_id, "value" => "tymeslot"} -> true
      _other -> false
    end)
  end

  defp tymeslot_origin?(_raw), do: false

  defp map_visibility("normal"), do: :public
  defp map_visibility("private"), do: :private
  defp map_visibility("confidential"), do: :confidential
  defp map_visibility(_other), do: nil

  defp map_transparency("free"), do: :transparent
  defp map_transparency(_other), do: :opaque

  defp map_status(%{"isCancelled" => true}), do: :cancelled
  defp map_status(%{"responseStatus" => %{"response" => "declined"}}), do: :declined
  defp map_status(%{"showAs" => "tentative"}), do: :tentative
  defp map_status(_raw), do: :confirmed

  defp map_organiser(nil), do: nil

  defp map_organiser(organiser) do
    %{
      email: get_in(organiser, ["emailAddress", "address"]),
      display_name: get_in(organiser, ["emailAddress", "name"])
    }
  end

  defp map_attendees(nil), do: []

  defp map_attendees(attendees) when is_list(attendees) do
    Enum.map(attendees, fn a ->
      %{
        email: get_in(a, ["emailAddress", "address"]),
        display_name: get_in(a, ["emailAddress", "name"]),
        response_status: map_response_status(get_in(a, ["status", "response"])),
        optional: a["type"] == "optional"
      }
    end)
  end

  defp map_response_status("accepted"), do: :accepted
  defp map_response_status("declined"), do: :declined
  defp map_response_status("tentativelyAccepted"), do: :tentative
  defp map_response_status("organizer"), do: :accepted
  defp map_response_status("notResponded"), do: :needs_action
  defp map_response_status("none"), do: :needs_action
  defp map_response_status(_other), do: :needs_action

  defp map_reminders(minutes) when is_integer(minutes) do
    [%{method: :popup, minutes_before: minutes}]
  end

  defp map_reminders(_other), do: []

  defp map_recurrence_rule(recurrence), do: RecurrenceConverter.outlook_to_rrule(recurrence)

  defp parse_timing(%{
         "isAllDay" => true,
         "start" => %{"dateTime" => start_dt},
         "end" => %{"dateTime" => end_dt}
       }) do
    with {:ok, sd} <- Date.from_iso8601(String.slice(start_dt, 0, 10)),
         {:ok, ed} <- Date.from_iso8601(String.slice(end_dt, 0, 10)) do
      %{all_day: true, start_date: sd, end_date: ed}
    else
      _error -> %{all_day: true, start_date: nil, end_date: nil}
    end
  end

  defp parse_timing(%{"start" => %{"dateTime" => start_dt}, "end" => %{"dateTime" => end_dt}}) do
    with {:ok, s, _offset} <- parse_iso8601_to_utc(start_dt),
         {:ok, e, _offset} <- parse_iso8601_to_utc(end_dt) do
      %{all_day: false, start_at: s, end_at: e}
    else
      _error -> %{all_day: false, start_at: nil, end_at: nil}
    end
  end

  defp parse_timing(_other), do: %{all_day: false, start_at: nil, end_at: nil}

  defp parse_iso8601_to_utc(datetime_str) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, dt, offset} ->
        {:ok, DateTime.shift_zone!(dt, "Etc/UTC"), offset}

      {:error, :missing_offset} ->
        case DateTime.from_iso8601(datetime_str <> "Z") do
          {:ok, dt, offset} -> {:ok, dt, offset}
          error -> error
        end

      error ->
        error
    end
  end

  # Prefer `originalStartTimeZone` from the Graph response — it preserves the
  # event's native zone regardless of the `Prefer: outlook.timezone="UTC"`
  # header we send on list requests. Fall back to `start.timeZone` when Graph
  # omits the original zone (e.g. externally-created events missing metadata).
  # Graph's `originalStartTimeZone` may be a Windows zone name
  # (`"Romance Standard Time"`) rather than IANA, so we route through
  # `Timezones.sanitize/1`, which performs the Windows→IANA conversion.
  defp maybe_put_timezone(attrs, %{"originalStartTimeZone" => tz})
       when is_binary(tz) and tz != "" do
    put_sanitized_timezone(attrs, tz)
  end

  defp maybe_put_timezone(attrs, %{"start" => %{"timeZone" => tz}})
       when is_binary(tz) and tz != "" do
    put_sanitized_timezone(attrs, tz)
  end

  defp maybe_put_timezone(attrs, _raw), do: attrs

  defp put_sanitized_timezone(attrs, tz) do
    case Timezones.sanitize(tz) do
      nil -> attrs
      clean -> Map.put(attrs, :timezone, clean)
    end
  end
end
