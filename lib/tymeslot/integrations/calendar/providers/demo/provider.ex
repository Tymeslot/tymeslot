defmodule Tymeslot.Integrations.Calendar.DemoCalendarProvider do
  @moduledoc """
  Demo calendar provider that generates sample calendar events for public demos.

  This provider:
  - Shows realistic availability patterns
  - Never marks demo bookings as busy
  - Provides consistent demo experience
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  # Reuse most functionality from debug provider
  alias Tymeslot.Integrations.Calendar.DebugCalendarProvider

  @impl Tymeslot.Integrations.Calendar.Provider
  defdelegate new(config), to: DebugCalendarProvider

  @impl Tymeslot.Integrations.Calendar.Provider
  def create_event(_client, _event_data) do
    # Demo mode: pretend to create the event but don't actually do anything
    {:ok, %{uid: "demo-event-#{:rand.uniform(999_999)}"}}
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def update_event(_client, _uid, _event_data) do
    # Demo mode: pretend to update successfully
    :ok
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def delete_event(_client, _uid) do
    # Demo mode: pretend to delete successfully
    :ok
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :demo

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "Demo Calendar"

  @impl Tymeslot.Integrations.Calendar.Provider
  defdelegate config_schema, to: DebugCalendarProvider

  @impl Tymeslot.Integrations.Calendar.Provider
  defdelegate validate_config(config), to: DebugCalendarProvider

  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events(client, opts) do
    DebugCalendarProvider.list_events(client, opts)
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def normalise_events(_raw_events, _context), do: {:ok, []}

  @impl Tymeslot.Integrations.Calendar.Provider
  def check_connectivity(_client), do: {:ok, %{status: :skipped, reason: "Demo provider"}}

  @doc """
  Tests the connection for the demo calendar provider.
  Always returns success.
  """
  @spec test_connection(term()) :: {:ok, String.t()}
  def test_connection(_integration) do
    {:ok, "Demo calendar connection successful"}
  end
end
