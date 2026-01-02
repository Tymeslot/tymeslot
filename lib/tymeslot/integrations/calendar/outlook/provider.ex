defmodule Tymeslot.Integrations.Calendar.Outlook.Provider do
  @moduledoc """
  Outlook/Microsoft Calendar provider implementation.

  This provider integrates with Microsoft Graph API using OAuth 2.0
  to fetch calendar events for availability calculation.
  """

  use Tymeslot.Integrations.Common.OAuthBase,
    provider_name: "outlook",
    display_name: "Outlook Calendar",
    base_url: "https://graph.microsoft.com/v1.0"

  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, MultiCalendarFetch, ProviderCommon}

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

      _ ->
        {:error, "Invalid oauth_scope format"}
    end
  end

  @spec convert_events(list(map())) :: list(map())
  def convert_events(outlook_events) do
    Enum.map(outlook_events, &convert_event/1)
  end

  @spec convert_event(map()) :: map()
  def convert_event(outlook_event) do
    %{
      uid: outlook_event.id,
      summary: outlook_event.summary,
      description: outlook_event.description,
      location: outlook_event.location,
      start_time: parse_datetime(outlook_event.start),
      end_time: parse_datetime(outlook_event.end),
      status: outlook_event.status
    }
  end

  @spec get_calendar_api_module() :: module()
  def get_calendar_api_module, do: api_module()

  @spec call_list_events(map(), DateTime.t(), DateTime.t()) ::
          {:ok, list(map())} | {:error, atom(), String.t()}
  def call_list_events(integration, start_time, end_time) do
    MultiCalendarFetch.list_events_with_selection(
      integration,
      start_time,
      end_time,
      api_module()
    )
  end

  @spec call_create_event(map(), map()) :: {:ok, map()} | {:error, atom(), String.t()}
  def call_create_event(integration, event_attrs) do
    # Use the default booking calendar if set
    calendar_id = integration.default_booking_calendar_id

    if calendar_id do
      api_module().create_event(integration, calendar_id, event_attrs)
    else
      # Fallback to default API method for backward compatibility
      api_module().create_event(integration, event_attrs)
    end
  end

  @spec call_update_event(map(), String.t(), map()) ::
          {:ok, map()} | {:error, atom(), String.t()}
  def call_update_event(integration, event_id, event_attrs) do
    # Use the default booking calendar if set
    calendar_id = integration.default_booking_calendar_id

    if calendar_id do
      api_module().update_event(integration, calendar_id, event_id, event_attrs)
    else
      # Fallback to default API method for backward compatibility
      api_module().update_event(integration, event_id, event_attrs)
    end
  end

  @spec call_delete_event(map(), String.t()) :: {:ok, term()} | {:error, atom(), String.t()}
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
  @spec discover_calendars(map()) :: {:ok, list(map())} | {:error, term()}
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
  @spec test_connection(map()) :: {:ok, String.t()} | {:error, term()}
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

      {:error, _type, reason} ->
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

  defp get_calendar_owner(_), do: "Unknown"

  defp parse_datetime(%{"dateTime" => datetime_str, "timeZone" => _timezone}) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_datetime(%{"dateTime" => datetime_str}) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_datetime(_), do: nil

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
