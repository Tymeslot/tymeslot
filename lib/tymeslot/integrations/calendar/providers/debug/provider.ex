defmodule Tymeslot.Integrations.Calendar.DebugCalendarProvider do
  @moduledoc """
  Debug calendar provider that generates predictable calendar events for testing.

  This provider creates realistic calendar scenarios without needing real calendar integration.
  Only available in development mode.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  alias Tymeslot.Integrations.Calendar.DebugSchedule

  # Synthetic events have no real timezone; default to UTC for the provider path.
  # The interactive dev calendar (`Tymeslot.Dev.Calendar`) resolves the
  # organiser's timezone instead.
  @default_timezone "Etc/UTC"

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
  def delete_event(_client, _uid, _opts \\ []) do
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
  def build_client_configs(integration) do
    if Application.get_env(:tymeslot, :environment) in [:dev, :test] do
      [%{user_id: integration.user_id}]
    else
      []
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def build_booking_client_config(_integration), do: nil

  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events(_client, opts) do
    start_time = opts[:start_time] || DateTime.add(DateTime.utc_now(), -7, :day)
    end_time = opts[:end_time] || DateTime.add(DateTime.utc_now(), 30, :day)
    events = DebugSchedule.events(:default, [], start_time, end_time, @default_timezone)
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
end
