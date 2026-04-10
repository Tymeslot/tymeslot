defmodule Tymeslot.Integrations.Calendar.Outlook.Provider do
  @moduledoc """
  Outlook/Microsoft Calendar provider implementation.

  This provider integrates with Microsoft Graph API using OAuth 2.0
  to fetch calendar events for availability calculation.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  use Tymeslot.Integrations.Common.OAuthBase,
    provider_name: "outlook",
    display_name: "Outlook Calendar",
    base_url: "https://graph.microsoft.com/v1.0"

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, MultiCalendarFetch, ProviderCommon}

  @typep converted_event :: %{
           required(:uid) => String.t() | nil,
           required(:summary) => String.t() | nil,
           required(:description) => String.t() | nil,
           required(:location) => String.t() | nil,
           required(:start_time) => DateTime.t() | Date.t() | nil,
           required(:end_time) => DateTime.t() | Date.t() | nil,
           required(:status) => String.t() | nil,
           required(:show_as) => String.t() | nil,
           required(:response_status) => String.t() | nil,
           required(:transparency) => String.t()
         }

  @typep calendar_entry :: %{
           required(:id) => String.t() | nil,
           required(:name) => String.t() | nil,
           required(:color) => String.t() | nil,
           required(:primary) => boolean(),
           required(:selected) => boolean(),
           required(:can_edit) => boolean() | nil,
           required(:owner) => String.t()
         }

  # Required callbacks for OAuth base

  @spec validate_oauth_scope(map()) :: :ok | {:error, String.t()}
  def validate_oauth_scope(config) do
    required_scopes = [
      "https://graph.microsoft.com/Calendars.ReadWrite",
      "https://graph.microsoft.com/Calendars.ReadWrite.Shared"
    ]

    case Map.get(config, :oauth_scope) do
      scope when is_binary(scope) ->
        if Enum.any?(required_scopes, &String.contains?(scope, &1)) or
             (String.contains?(scope, "Calendars.ReadWrite") or
                String.contains?(scope, "Calendars.Read")) do
          :ok
        else
          {:error,
           "OAuth scope must include Calendars.ReadWrite permission for read/write access"}
        end

      _invalid ->
        {:error, "Invalid oauth_scope format"}
    end
  end

  # --- Provider behaviour ---

  @impl Tymeslot.Integrations.Calendar.Provider
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
      %{"value" => "tymeslot"} -> true
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

  defp map_recurrence_rule(%{"pattern" => pattern, "range" => range}) do
    type = Map.get(pattern, "type", "")
    interval = Map.get(pattern, "interval", 1)
    range_type = Map.get(range, "type", "")

    "FREQ=#{String.upcase(type)};INTERVAL=#{interval};RANGE_TYPE=#{range_type}"
  end

  defp map_recurrence_rule(_other), do: nil

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

  defp maybe_put_timezone(attrs, %{"start" => %{"timeZone" => tz}}),
    do: Map.put(attrs, :timezone, tz)

  defp maybe_put_timezone(attrs, _raw), do: attrs

  # --- Legacy conversion (used by OAuthBase get_events / create_event / update_event) ---

  @spec convert_events(list(map())) :: list(converted_event())
  def convert_events(outlook_events) do
    outlook_events
    |> Enum.filter(&busy_event?/1)
    |> Enum.map(&convert_event/1)
  end

  defp busy_event?(event) do
    status = Map.get(event, :status)
    response_status = Map.get(event, :response_status)

    status != "cancelled" and response_status != "declined"
  end

  @spec convert_event(map()) :: converted_event()
  def convert_event(outlook_event) do
    start_time = parse_datetime(outlook_event[:start], outlook_event[:is_all_day])
    end_time = parse_datetime(outlook_event[:end], outlook_event[:is_all_day])

    %{
      uid: outlook_event[:id] || outlook_event[:uid],
      summary: outlook_event[:summary],
      description: outlook_event[:description],
      location: outlook_event[:location],
      start_time: start_time,
      end_time: end_time,
      status: outlook_event[:status],
      show_as: outlook_event[:show_as],
      response_status: outlook_event[:response_status],
      transparency: if(outlook_event[:show_as] == "free", do: "transparent", else: "opaque")
    }
  end

  @spec get_calendar_api_module() :: module()
  def get_calendar_api_module, do: api_module()

  @spec call_list_events(CalendarIntegrationSchema.t(), DateTime.t(), DateTime.t()) ::
          {:ok, list(map())} | {:error, atom(), String.t()}
  def call_list_events(integration, start_time, end_time) do
    MultiCalendarFetch.list_events_with_selection(
      integration,
      start_time,
      end_time,
      api_module()
    )
  end

  @spec call_create_event(CalendarIntegrationSchema.t(), map()) ::
          {:ok, map()} | {:error, atom(), String.t()}
  def call_create_event(integration, event_attrs) do
    calendar_id = event_attrs[:calendar_id] || integration.default_booking_calendar_id

    if calendar_id do
      api_module().create_event(integration, calendar_id, event_attrs)
    else
      api_module().create_event(integration, event_attrs)
    end
  end

  @spec call_update_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, map()} | {:error, atom(), String.t()}
  def call_update_event(integration, event_id, event_attrs) do
    calendar_id = event_attrs[:calendar_id] || integration.default_booking_calendar_id
    # Prefer the provider-native event ID when available (avoids iCalUID→ID conversion)
    effective_id = event_attrs[:provider_event_id] || event_id

    if calendar_id do
      api_module().update_event(integration, calendar_id, effective_id, event_attrs)
    else
      api_module().update_event(integration, effective_id, event_attrs)
    end
  end

  @spec call_delete_event(CalendarIntegrationSchema.t(), String.t()) ::
          :ok | {:error, atom(), String.t()}
  def call_delete_event(integration, event_id) do
    # Use the default booking calendar if set
    calendar_id = integration.default_booking_calendar_id

    if calendar_id do
      api_module().delete_event(integration, calendar_id, event_id)
    else
      # Fallback to default API method for backward compatibility
      api_module().delete_event(integration, event_id)
    end
  end

  @doc """
  Discovers all available calendars for the authenticated Outlook account.
  """
  @spec discover_calendars(CalendarIntegrationSchema.t()) ::
          {:ok, list(calendar_entry())} | {:error, term()}
  def discover_calendars(integration) do
    ProviderCommon.discover_calendars(
      integration,
      fn int -> api_module().list_calendars(int) end,
      &format_calendar/1
    )
  end

  @doc """
  Tests the connection to Microsoft Graph API.
  Makes a simple API call to verify OAuth token validity and API accessibility.
  """
  @spec test_connection(CalendarIntegrationSchema.t()) :: {:ok, String.t()} | {:error, term()}
  def test_connection(integration) do
    case api_module().list_primary_events(
           integration,
           DateTime.utc_now(),
           DateTime.add(DateTime.utc_now(), 1, :day)
         ) do
      {:ok, _events} ->
        {:ok, "Outlook Calendar connection successful"}

      {:error, :unauthorized, _message} ->
        {:error, :unauthorized}

      {:error, :rate_limited, _message} ->
        {:error, "Rate limited - please try again later"}

      {:error, _error_type, reason} ->
        message = ErrorHandler.sanitize_error_message(reason, :outlook)

        {:error, message}
    end
  end

  # Private helper functions

  defp api_module do
    Application.get_env(:tymeslot, :outlook_calendar_api_module, CalendarAPI)
  end

  defp get_calendar_owner(%{"owner" => owner}) when is_map(owner) do
    owner["name"] || owner["address"] || "Unknown"
  end

  defp get_calendar_owner(_calendar), do: "Unknown"

  defp parse_datetime(time_map, is_all_day)

  defp parse_datetime(%{"dateTime" => datetime_str}, true) do
    # For all-day events, Outlook returns the date part + 00:00:00
    # We strip the time part and return just the Date
    case Date.from_iso8601(String.slice(datetime_str, 0, 10)) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(%{"dateTime" => datetime_str, "timeZone" => _tz}, _is_all_day) do
    parse_iso8601_lenient(datetime_str)
  end

  defp parse_datetime(%{"dateTime" => datetime_str}, _is_all_day) do
    parse_iso8601_lenient(datetime_str)
  end

  defp parse_datetime(_other, _is_all_day), do: nil

  defp parse_iso8601_lenient(datetime_str) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, :missing_offset} ->
        # Try appending Z if it's missing (often the case with some providers)
        case DateTime.from_iso8601(datetime_str <> "Z") do
          {:ok, datetime, _offset} -> datetime
          {:error, _reason} -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp format_calendar(cal) do
    %{
      id: cal["id"],
      name: cal["name"],
      color: cal["color"],
      primary: cal["isDefaultCalendar"] || false,
      selected: cal["isDefaultCalendar"] || false,
      can_edit: cal["canEdit"],
      owner: get_calendar_owner(cal)
    }
  end
end
