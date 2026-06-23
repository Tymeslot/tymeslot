defmodule Tymeslot.Integrations.Calendar.Outlook.EventMapper do
  @moduledoc """
  Maps outbound event data from Tymeslot's internal format to
  Microsoft Graph API format for Outlook Calendar operations.
  """

  alias Tymeslot.Integrations.Calendar.EventTimeFormatter

  @outlook_tymeslot_property_id "String {00020329-0000-0000-C000-000000000046} Name createdBy"

  @doc """
  Converts Tymeslot event data into the Microsoft Graph event format.
  """
  @spec format_event_data(map()) :: map()
  def format_event_data(event_data) do
    base = %{
      "subject" => extract_field(event_data, :summary, "summary"),
      "body" => build_event_body(event_data),
      "location" => build_event_location(event_data),
      "start" => build_event_datetime(event_data, :start_time, "start_time"),
      "end" => build_event_datetime(event_data, :end_time, "end_time"),
      "showAs" => map_show_as(event_data),
      "sensitivity" => map_sensitivity(event_data),
      "attendees" => build_attendees(event_data)
    }

    base =
      if all_day_event?(event_data),
        do: Map.put(base, "isAllDay", true),
        else: base

    base
    |> add_reminder(event_data)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  @doc """
  Adds the Tymeslot fingerprint extended property to a Graph API event body,
  so that events created by Tymeslot can be identified later during sync.
  """
  @spec add_tymeslot_fingerprint(map()) :: map()
  def add_tymeslot_fingerprint(body) do
    Map.put(body, "singleValueExtendedProperties", [
      %{"id" => @outlook_tymeslot_property_id, "value" => "tymeslot"}
    ])
  end

  # Private helpers

  defp build_attendees(event_data) do
    attendees = extract_field(event_data, :attendees, "attendees")

    if is_list(attendees) and attendees != [] do
      attendees
      |> Enum.map(fn attendee ->
        email = attendee["email"] || attendee[:email]
        name = attendee["name"] || attendee[:name]

        if email do
          %{
            "emailAddress" => %{"address" => email, "name" => name || email},
            "type" => "required"
          }
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      # Legacy single-attendee path (ad-hoc meetings)
      email = extract_field(event_data, :attendee_email, "attendee_email")
      name = extract_field(event_data, :attendee_name, "attendee_name")

      if email do
        [
          %{
            "emailAddress" => %{"address" => email, "name" => name || email},
            "type" => "required"
          }
        ]
      else
        []
      end
    end
  end

  defp extract_field(event_data, atom_key, string_key) do
    Map.get(event_data, atom_key) || Map.get(event_data, string_key)
  end

  defp build_event_body(event_data) do
    %{
      "contentType" => "Text",
      "content" => extract_field(event_data, :description, "description") || ""
    }
  end

  defp build_event_location(event_data) do
    %{
      "displayName" => extract_field(event_data, :location, "location") || ""
    }
  end

  defp build_event_datetime(event_data, atom_key, string_key) do
    datetime = extract_field(event_data, atom_key, string_key)
    timezone = extract_field(event_data, :timezone, "timezone")

    case datetime do
      %Date{} = date ->
        # Outlook requires dateTime format even for all-day events
        %{
          "dateTime" => "#{Date.to_iso8601(date)}T00:00:00.0000000",
          "timeZone" => timezone || "UTC"
        }

      _other ->
        EventTimeFormatter.format_with_timezone(
          datetime,
          timezone,
          include_when_missing?: true,
          include_timezone_on_error?: true
        )
    end
  end

  defp map_show_as(event_data) do
    transparency = extract_field(event_data, :transparency, "transparency")
    status = extract_field(event_data, :status, "status")

    cond do
      transparency in [:transparent, "transparent"] -> "free"
      status in [:tentative, "tentative"] -> "tentative"
      true -> "busy"
    end
  end

  defp map_sensitivity(event_data) do
    case extract_field(event_data, :visibility, "visibility") do
      v when v in [:private, "private"] -> "private"
      v when v in [:confidential, "confidential"] -> "confidential"
      _other -> nil
    end
  end

  defp all_day_event?(event_data) do
    start_time = extract_field(event_data, :start_time, "start_time")
    match?(%Date{}, start_time)
  end

  # Microsoft Graph models a single lead-time reminder per event via
  # `reminderMinutesBeforeStart` + `isReminderOn` — it has no per-reminder
  # method and cannot represent multiple reminders. Only the first reminder's
  # lead time round-trips; additional reminders are dropped on the Outlook path.
  defp add_reminder(base, event_data) do
    # Reminders may be atom-keyed (freshly built) or string-keyed (round-tripped
    # through the JSONB cache column); read both forms.
    case extract_field(event_data, :reminders, "reminders") do
      [first | _rest] when is_map(first) ->
        minutes = first[:minutes_before] || first["minutes_before"]

        base
        |> Map.put("isReminderOn", true)
        |> Map.put("reminderMinutesBeforeStart", minutes)

      _none ->
        Map.put(base, "isReminderOn", false)
    end
  end
end
