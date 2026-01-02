defmodule Tymeslot.Integrations.Calendar.DemoCalendarProvider do
  @moduledoc """
  Demo calendar provider that generates sample calendar events for public demos.

  This provider:
  - Shows realistic availability patterns
  - Never marks demo bookings as busy
  - Provides consistent demo experience
  """

  @behaviour Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour

  # Reuse most functionality from debug provider
  alias Tymeslot.Integrations.Calendar.DebugCalendarProvider

  @impl true
  defdelegate new(config), to: DebugCalendarProvider

  @impl true
  defdelegate get_events(client), to: DebugCalendarProvider

  @impl true
  defdelegate get_events(client, start_time, end_time), to: DebugCalendarProvider

  @impl true
  def create_event(_client, _event_data) do
    # Demo mode: pretend to create the event but don't actually do anything
    {:ok, %{uid: "demo-event-#{:rand.uniform(999_999)}"}}
  end

  @impl true
  def update_event(_client, _uid, _event_data) do
    # Demo mode: pretend to update successfully
    :ok
  end

  @impl true
  def delete_event(_client, _uid) do
    # Demo mode: pretend to delete successfully
    :ok
  end

  @impl true
  def provider_type, do: :demo

  @impl true
  def display_name, do: "Demo Calendar"

  @impl true
  defdelegate config_schema, to: DebugCalendarProvider

  @impl true
  defdelegate validate_config(config), to: DebugCalendarProvider

  @doc """
  Tests the connection for the demo calendar provider.
  Always returns success.
  """
  def test_connection(_integration) do
    {:ok, "Demo calendar connection successful"}
  end
end
