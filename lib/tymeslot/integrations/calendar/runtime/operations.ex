defmodule Tymeslot.Integrations.Calendar.Operations do
  @moduledoc """
  Implements CalendarBehaviour for testing and configuration compatibility.

  This module exists solely to implement the CalendarBehaviour interface,
  allowing tests to swap implementations via Application config.

  All actual logic lives in focused modules:
  - ClientManager - Client creation and booking resolution
  - EventOperations - Event CRUD operations
  - EventQueries - Event query operations
  """

  @behaviour Tymeslot.Integrations.Calendar.CalendarBehaviour
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Integrations.Calendar.Runtime.EventOperations
  alias Tymeslot.Integrations.Calendar.Runtime.EventQueries

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def list_events_in_range(user_id, start_date_or_dt, end_date_or_dt) do
    EventQueries.list_events_in_range(user_id, start_date_or_dt, end_date_or_dt)
  end

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def get_events_for_range_fresh(user_id, start_date, end_date) do
    EventQueries.get_events_for_range_fresh(user_id, start_date, end_date)
  end

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def get_events_for_month(user_id, year, month, timezone) do
    EventQueries.get_events_for_month(user_id, year, month, timezone)
  end

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def get_event(uid, user_id \\ nil) do
    EventOperations.get_event(uid, user_id)
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

  @spec delete_event(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def delete_event(uid, context, opts) do
    EventOperations.delete_event(uid, context, opts)
  end

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def get_booking_integration_info(context) do
    ClientManager.get_booking_integration_info(context)
  end
end
