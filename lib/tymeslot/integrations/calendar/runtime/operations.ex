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
  alias Tymeslot.Integrations.Calendar.CalDAV.QueueWiring
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Integrations.Calendar.Runtime.EventFetcher
  alias Tymeslot.Integrations.Calendar.Runtime.EventOperations

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def get_events_for_range_fresh(user_id, start_date, end_date) do
    EventFetcher.get_events_for_range_fresh(user_id, start_date, end_date)
  end

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def get_events_for_month(user_id, year, month, timezone) do
    EventFetcher.get_events_for_month(user_id, year, month, timezone)
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

  @spec delete_event_and_reconcile(
          String.t(),
          String.t() | nil,
          {integer(), integer()},
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def delete_event_and_reconcile(uid, provider_event_id, context, opts \\ []) do
    EventOperations.delete_event_and_reconcile(uid, provider_event_id, context, opts)
  end

  @spec event_linked_to_booking?(integer(), String.t() | nil, String.t() | nil) :: boolean()
  def event_linked_to_booking?(integration_id, provider_event_id, uid) do
    EventOperations.event_linked_to_booking?(integration_id, provider_event_id, uid)
  end

  @impl Tymeslot.Integrations.Calendar.CalendarBehaviour
  def get_booking_integration_info(context) do
    ClientManager.get_booking_integration_info(context)
  end

  @doc """
  Tags a calendar event cache row for offline retry on the next sync cycle.

  Delegates to `QueueWiring.tag/3`. Returns `:ok` when the row is queued,
  or `:ignored` when the meeting's integration is not a CalDAV-family provider.
  """
  @spec tag_for_offline_retry(QueueWiring.meeting(), QueueWiring.action(), map()) ::
          :ok | :ignored
  def tag_for_offline_retry(meeting, action, event_data) do
    QueueWiring.tag(meeting, action, event_data)
  end
end
