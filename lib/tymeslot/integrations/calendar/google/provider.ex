defmodule Tymeslot.Integrations.Calendar.Google.Provider do
  @moduledoc """
  Google Calendar provider implementation.

  This provider integrates with Google Calendar API using OAuth 2.0
  to fetch calendar events for availability calculation.
  """

  use Tymeslot.Integrations.Common.OAuthBase,
    provider_name: "google",
    display_name: "Google Calendar",
    base_url: "https://www.googleapis.com/calendar/v3"

  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, ProviderCommon}
  alias Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetch

  @doc """
  Checks if a Google Calendar integration needs a scope upgrade.
  Returns true if the integration only has basic auth scope without calendar permissions.
  """
  @spec needs_scope_upgrade?(term()) :: boolean()
  def needs_scope_upgrade?(%CalendarIntegrationSchema{oauth_scope: scope})
      when is_binary(scope) do
    !String.contains?(scope, "calendar")
  end

  def needs_scope_upgrade?(_), do: false

  # Required callbacks for OAuth base

  @spec validate_oauth_scope(map()) :: :ok | {:error, String.t()}
  def validate_oauth_scope(config) do
    required_scopes = [
      "https://www.googleapis.com/auth/calendar",
      "https://www.googleapis.com/auth/calendar.events"
    ]

    case Map.get(config, :oauth_scope) do
      scope when is_binary(scope) ->
        if Enum.any?(required_scopes, &String.contains?(scope, &1)) or
             String.contains?(scope, "calendar") do
          :ok
        else
          {:error, "OAuth scope must include calendar permission for read/write access"}
        end

      _ ->
        {:error, "Invalid oauth_scope format"}
    end
  end

  @spec convert_events(list(map())) :: list(map())
  def convert_events(google_events) do
    Enum.map(google_events, &convert_event/1)
  end

  @spec convert_event(map()) :: map()
  def convert_event(google_event) do
    %{
      uid: google_event["id"],
      summary: google_event["summary"],
      description: google_event["description"],
      location: google_event["location"],
      start_time: parse_datetime(google_event["start"]),
      end_time: parse_datetime(google_event["end"]),
      status: google_event["status"]
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
    # Use the default booking calendar if set, otherwise use primary
    calendar_id = integration.default_booking_calendar_id || "primary"
    api_module().create_event(integration, calendar_id, event_attrs)
  end

  @spec call_update_event(map(), String.t(), map()) ::
          {:ok, map()} | {:error, atom(), String.t()}
  def call_update_event(integration, event_id, event_attrs) do
    # Use the default booking calendar if set, otherwise use primary
    calendar_id = integration.default_booking_calendar_id || "primary"
    api_module().update_event(integration, calendar_id, event_id, event_attrs)
  end

  @spec call_delete_event(map(), String.t()) :: {:ok, term()} | {:error, atom(), String.t()}
  def call_delete_event(integration, event_id) do
    # Use the default booking calendar if set, otherwise use primary
    calendar_id = integration.default_booking_calendar_id || "primary"
    api_module().delete_event(integration, calendar_id, event_id)
  end

  @doc """
  Discovers all available calendars for the authenticated Google account.
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
  Tests the connection to Google Calendar API.
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
        {:ok, "Google Calendar connection successful"}

      {:error, :unauthorized, _message} ->
        {:error, :unauthorized}

      {:error, :rate_limited, _message} ->
        {:error, "Rate limited - please try again later"}

      {:error, _type, reason} ->
        message = ErrorHandler.sanitize_error_message(reason, :google)

        {:error, message}
    end
  end

  # Private helper functions

  defp api_module do
    Application.get_env(:tymeslot, :google_calendar_api_module, CalendarAPI)
  end

  defp parse_datetime(%{"dateTime" => datetime_str}) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_datetime(%{"date" => date_str}) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00])
      {:error, _} -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp format_calendar(cal) do
    %{
      id: cal["id"],
      name: cal["summary"] || cal["id"],
      description: cal["description"],
      primary: cal["primary"] || false,
      selected: cal["primary"] || false,
      access_role: cal["accessRole"],
      color: cal["backgroundColor"]
    }
  end
end
