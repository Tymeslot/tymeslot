defmodule Tymeslot.Integrations.Calendar.DebugCalendarProvider do
  @moduledoc """
  Debug calendar provider that generates predictable calendar events for testing.

  This provider creates realistic calendar scenarios without needing real calendar integration.
  Only available in development mode.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  @impl Tymeslot.Integrations.Calendar.Provider
  def new(config) when is_map(config) do
    case validate_config(config) do
      :ok -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def create_event(_client, _event_data) do
    {:error, "Debug calendar provider does not support event creation"}
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def update_event(_client, _uid, _event_data) do
    {:error, "Debug calendar provider does not support event updates"}
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def delete_event(_client, _uid) do
    {:error, "Debug calendar provider does not support event deletion"}
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :debug

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "Debug Calendar (Development Only)"

  @impl Tymeslot.Integrations.Calendar.Provider
  def config_schema do
    %{
      user_id: %{
        type: :integer,
        required: true,
        description: "User ID for debug calendar"
      }
    }
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def validate_config(config) do
    if Map.has_key?(config, :user_id) do
      :ok
    else
      {:error, "user_id is required for debug calendar provider"}
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events(_client, opts) do
    start_time = opts[:start_time] || DateTime.add(DateTime.utc_now(), -7, :day)
    end_time = opts[:end_time] || DateTime.add(DateTime.utc_now(), 30, :day)
    events = generate_debug_events(start_time, end_time)
    {:ok, events}
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def normalise_events(_raw_events, _context), do: {:ok, []}

  @impl Tymeslot.Integrations.Calendar.Provider
  def check_connectivity(_client), do: {:ok, %{status: :skipped, reason: "Debug provider"}}

  @doc """
  Tests the connection for the debug calendar provider.
  Always returns success since this is a test provider.
  """
  @spec test_connection(map()) :: {:ok, String.t()}
  def test_connection(_integration) do
    {:ok, "Debug calendar connection successful"}
  end

  # Private functions

  defp generate_debug_events(start_time, end_time) do
    today = DateTime.to_date(DateTime.utc_now())

    # Generate events for the next 7 days
    0..6
    |> Enum.flat_map(fn days_offset ->
      date = Date.add(today, days_offset)
      generate_events_for_date(date)
    end)
    |> Enum.filter(fn event ->
      DateTime.compare(event.start_time, start_time) != :lt and
        DateTime.compare(event.end_time, end_time) != :gt
    end)
  end

  defp generate_events_for_date(date) do
    case Date.day_of_week(date) do
      # Monday - Light day
      1 ->
        [
          create_event(date, ~T[09:00:00], ~T[10:00:00], "Monday Morning Standup"),
          create_event(date, ~T[14:00:00], ~T[15:00:00], "Project Review")
        ]

      # Tuesday - Busy day
      2 ->
        [
          create_event(date, ~T[09:00:00], ~T[09:30:00], "Quick Check-in"),
          create_event(date, ~T[10:00:00], ~T[11:00:00], "Client Meeting"),
          create_event(date, ~T[12:00:00], ~T[13:00:00], "Lunch Meeting"),
          create_event(date, ~T[15:00:00], ~T[16:00:00], "Team Sync"),
          create_event(date, ~T[16:30:00], ~T[17:00:00], "Wrap-up Call")
        ]

      # Wednesday - All-day event
      3 ->
        [
          create_event(date, ~T[09:00:00], ~T[17:00:00], "Company All-Hands")
        ]

      # Thursday - No events (fully available)
      4 ->
        []

      # Friday - Afternoon meetings
      5 ->
        [
          create_event(date, ~T[13:00:00], ~T[14:00:00], "Weekly Planning"),
          create_event(date, ~T[15:30:00], ~T[16:30:00], "Sprint Retrospective")
        ]

      # Weekend - No events
      _weekend ->
        []
    end
  end

  defp create_event(date, start_time, end_time, summary) do
    timezone = "America/New_York"

    {:ok, start_datetime} = DateTime.new(date, start_time, timezone)
    {:ok, end_datetime} = DateTime.new(date, end_time, timezone)

    %{
      uid: "debug-#{Date.to_string(date)}-#{Time.to_string(start_time)}",
      summary: summary,
      start_time: start_datetime,
      end_time: end_datetime,
      description: "Debug calendar event for testing availability",
      location: "Debug Location",
      organizer: "debug@localhost.dev",
      attendees: [],
      status: "confirmed"
    }
  end
end
