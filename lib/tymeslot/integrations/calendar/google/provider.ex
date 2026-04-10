defmodule Tymeslot.Integrations.Calendar.Google.Provider do
  @moduledoc """
  Google Calendar provider implementation.

  This provider integrates with Google Calendar API using OAuth 2.0
  to fetch calendar events for availability calculation.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  use Tymeslot.Integrations.Common.OAuthBase,
    provider_name: "google",
    display_name: "Google Calendar",
    base_url: "https://www.googleapis.com/calendar/v3"

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, ProviderCommon}
  alias Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetch

  @typep converted_event :: %{
           required(:uid) => String.t() | nil,
           required(:summary) => String.t() | nil,
           required(:description) => String.t() | nil,
           required(:location) => String.t() | nil,
           required(:start_time) => DateTime.t() | Date.t() | nil,
           required(:end_time) => DateTime.t() | Date.t() | nil,
           required(:status) => String.t() | nil,
           required(:transparency) => String.t() | nil
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

  @doc """
  Checks if a Google Calendar integration needs a scope upgrade.
  Returns true if the integration only has basic auth scope without calendar permissions.
  """
  @spec needs_scope_upgrade?(term()) :: boolean()
  def needs_scope_upgrade?(%CalendarIntegrationSchema{oauth_scope: scope})
      when is_binary(scope) do
    !String.contains?(scope, "calendar")
  end

  def needs_scope_upgrade?(_scope), do: false

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

      _other ->
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
            Logger.warning("Skipping invalid Google calendar event",
              reason: reason,
              event_id: raw["id"],
              calendar_integration_id: context.calendar_integration_id
            )

            AdminAlerts.send_alert(:invalid_calendar_event, %{
              provider: :google,
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
        colour: raw["colorId"],
        etag: raw["etag"],
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

  defp maybe_put_timezone(attrs, %{"start" => %{"timeZone" => tz}}),
    do: Map.put(attrs, :timezone, tz)

  defp maybe_put_timezone(attrs, _raw), do: attrs

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
      start_time: parse_datetime(google_event["start"]),
      end_time: parse_datetime(google_event["end"]),
      status: google_event["status"],
      transparency: google_event["transparency"]
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
