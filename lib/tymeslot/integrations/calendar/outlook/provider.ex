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

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.EventNormaliser
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
    EventNormaliser.normalise_events(raw_events, context)
  end

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
