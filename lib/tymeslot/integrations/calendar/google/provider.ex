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

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.{CalendarAPI, EventNormaliser}
  alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, ProviderCommon}
  alias Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetch

  @typep converted_event :: %{
           required(:uid) => String.t() | nil,
           required(:summary) => String.t() | nil,
           required(:description) => String.t() | nil,
           required(:location) => String.t() | nil,
           required(:all_day) => boolean(),
           required(:start_time) => DateTime.t() | Date.t() | nil,
           required(:end_time) => DateTime.t() | Date.t() | nil,
           required(:status) => String.t() | nil,
           required(:transparency) => String.t() | nil,
           required(:meet_url) => String.t() | nil
         }

  @typep calendar_entry :: %{
           required(:id) => String.t() | nil,
           required(:name) => String.t() | nil,
           required(:description) => String.t() | nil,
           required(:primary) => boolean(),
           required(:selected) => boolean(),
           required(:access_role) => String.t() | nil,
           required(:color) => String.t() | nil
         }

  # Scopes that grant write access to calendar events. Required for Google Meet
  # creation via calendar.v3.Events.Insert. `calendar.readonly` and
  # `calendar.events.readonly` are intentionally excluded.
  @calendar_write_scopes MapSet.new([
                           "https://www.googleapis.com/auth/calendar",
                           "https://www.googleapis.com/auth/calendar.events"
                         ])

  @doc """
  Returns true when the integration's stored scope lacks any write-capable
  calendar scope. Read-only and absent scopes both qualify.
  """
  @spec needs_scope_upgrade?(term()) :: boolean()
  def needs_scope_upgrade?(%CalendarIntegrationSchema{oauth_scope: scope})
      when is_binary(scope) do
    not has_calendar_write_scope?(scope)
  end

  def needs_scope_upgrade?(_integration), do: false

  @doc """
  Returns true when the given OAuth scope string grants calendar event write
  access. Exposed for the OAuth callback to validate freshly returned tokens
  before persisting an integration.
  """
  @spec has_calendar_write_scope?(String.t() | nil) :: boolean()
  def has_calendar_write_scope?(scope) when is_binary(scope) do
    granted = scope |> String.split(" ", trim: true) |> MapSet.new()
    not MapSet.disjoint?(@calendar_write_scopes, granted)
  end

  def has_calendar_write_scope?(_scope), do: false

  # Required callbacks for OAuth base

  @spec validate_oauth_scope(map()) :: :ok | {:error, String.t()}
  def validate_oauth_scope(config) do
    case Map.get(config, :oauth_scope) do
      scope when is_binary(scope) ->
        if has_calendar_write_scope?(scope) do
          :ok
        else
          {:error,
           "OAuth scope must grant calendar write access (calendar.readonly is not sufficient)"}
        end

      _other ->
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
  def convert_events(google_events) do
    Enum.map(google_events, &convert_event/1)
  end

  @spec convert_event(map()) :: converted_event()
  def convert_event(google_event) do
    %{
      uid: google_event["id"],
      summary: google_event["summary"],
      description: google_event["description"],
      location: google_event["location"],
      all_day: all_day_google_event?(google_event),
      start_time: parse_datetime(google_event["start"]),
      end_time: parse_datetime(google_event["end"]),
      status: google_event["status"],
      transparency: google_event["transparency"],
      meet_url: extract_meet_url(google_event)
    }
  end

  @doc false
  @spec extract_meet_url(map()) :: String.t() | nil
  def extract_meet_url(google_event) when is_map(google_event) do
    case get_in(google_event, ["conferenceData", "entryPoints"]) do
      entry_points when is_list(entry_points) ->
        video_entry_point_uri(entry_points)

      _other ->
        nil
    end
  end

  def extract_meet_url(_other), do: nil

  defp video_entry_point_uri(entry_points) do
    case Enum.find(entry_points, fn ep -> ep["entryPointType"] == "video" end) do
      %{"uri" => uri} when is_binary(uri) and uri != "" -> uri
      _other -> nil
    end
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
    calendar_id =
      event_attrs[:calendar_id] || integration.default_booking_calendar_id || "primary"

    api_module().create_event(integration, calendar_id, event_attrs)
  end

  @spec call_update_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, map()} | {:error, atom(), String.t()}
  def call_update_event(integration, event_id, event_attrs) do
    calendar_id =
      event_attrs[:calendar_id] || integration.default_booking_calendar_id || "primary"

    # Prefer the provider-native event ID when available (avoids iCalUID→ID conversion)
    effective_id = event_attrs[:provider_event_id] || event_id
    api_module().update_event(integration, calendar_id, effective_id, event_attrs)
  end

  @spec call_delete_event(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, term()} | {:error, atom(), String.t()}
  def call_delete_event(integration, event_id) do
    calendar_id = integration.default_booking_calendar_id || "primary"
    api_module().delete_event(integration, calendar_id, event_id)
  end

  @doc """
  Discovers all available calendars for the authenticated Google account.
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

  @impl Tymeslot.Integrations.Calendar.Provider
  def discover_calendars_for_integration(integration), do: discover_calendars(integration)

  @impl Tymeslot.Integrations.Calendar.Provider
  def build_client_configs(integration), do: [integration]

  @impl Tymeslot.Integrations.Calendar.Provider
  def build_booking_client_config(integration), do: integration

  @doc """
  Tests the connection to Google Calendar API.
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

  defp all_day_google_event?(%{"start" => %{"date" => _date}}), do: true
  defp all_day_google_event?(_other), do: false

  defp parse_datetime(%{"dateTime" => datetime_str}) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(%{"date" => date_str}) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_other), do: nil

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
