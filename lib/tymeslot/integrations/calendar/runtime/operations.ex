defmodule Tymeslot.Integrations.Calendar.Operations do
  @moduledoc """
  Implements CalendarBehaviour for testing and configuration compatibility.

  This module exists solely to implement the CalendarBehaviour interface,
  allowing tests to swap implementations via Application config.

  All actual logic lives in focused modules:
  - ClientManager - Client creation and booking resolution
  - EventOperations - Event CRUD operations
  - EventFetcher - Provider event fetches
  """

  @behaviour Tymeslot.Integrations.Calendar.CalendarBehaviour
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Integrations.Calendar.Runtime.EventFetcher
  alias Tymeslot.Integrations.Calendar.Runtime.EventOperations

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def get_events_for_range_fresh(user_id, start_date, end_date) do
    EventFetcher.get_events_for_range_fresh(user_id, start_date, end_date)
  end

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def create_event(event_data, context) do
    EventOperations.create_event(event_data, context)
  end

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def update_event(uid, event_data, context) do
    EventOperations.update_event(uid, event_data, context)
  end

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def delete_event(uid, context) do
    EventOperations.delete_event(uid, context, [])
  end

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def delete_event(uid, context, opts) do
    EventOperations.delete_event(uid, context, opts)
  end

  @doc """
  Fetches one event straight from its calendar provider. See
  `EventOperations.fetch_event/2`.
  """
  @spec fetch_event(map(), {integer(), integer()}) ::
          {:ok, list()} | {:error, :not_found} | {:error, term()}
  def fetch_event(event_ref, context) do
    EventOperations.fetch_event(event_ref, context)
  end

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def get_booking_integration_info(context) do
    ClientManager.get_booking_integration_info(context)
  end
end
