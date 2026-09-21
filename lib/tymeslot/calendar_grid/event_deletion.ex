defmodule Tymeslot.CalendarGrid.EventDeletion do
  @moduledoc """
  Deleting a calendar-grid event: the provider delete, the Tymeslot meeting
  it may have been booked as, and the cached row the grid reads. Whenever the
  row changes, the organiser's cached availability is invalidated so the
  booking page stops treating the slot as taken.

  ## Linked meetings

  An event that is the calendar copy of a Tymeslot booking takes the booking
  with it: once the provider has deleted the event, the meeting is reconciled
  as externally deleted (see `Calendar.Events.delete_event_and_reconcile/4`),
  and the result says whether that cancellation went through. Nothing is
  reconciled when the delete fails.

  ## Recurring events

  An event that belongs to a series is refused with `:recurring_event`. For
  the CalDAV family every occurrence is addressed by the one resource that
  holds the whole series, so deleting "this Tuesday" would delete every
  occurrence on the organiser's calendar, and no provider has a scoped delete
  yet. The check reads the cached row rather than the event it was handed,
  because callers pass only the fields that address the event.

  ## Failure

  A failed delete is queued for replay on the next sync when the error is one
  a retry can recover (see `Calendar.Events.queueable_error?/1`) and the
  integration has an offline queue (the CalDAV family). The queue marks the
  cached row `locally_deleted`, and the replay removes it once the server has
  deleted the event.

  Only a delete the calendar refused is reported as a failure. Once the
  provider has removed the event there is nothing left to retry, so the
  local tidying that follows (the linked meeting, the cached row, the
  organiser's cached availability) can fail without changing the answer: the
  failure is logged, and the delete still returns `{:ok, deleted}`. The
  linked meeting is the one such step the organiser is told about, as
  `:cancel_failed`.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EventMove
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  @type event :: %{
          required(:uid) => String.t(),
          required(:calendar_integration_id) => pos_integer(),
          optional(:provider_event_id) => String.t() | nil,
          optional(atom()) => term()
        }

  @typedoc """
  What happened to the Tymeslot meeting the event was booked as: `:none` when
  it was not a booking, `:cancelled` when the meeting was cancelled with it,
  `:cancel_failed` when the event is gone but the meeting could not be
  cancelled.
  """
  @type linked_meeting :: :none | :cancelled | :cancel_failed

  @type deleted :: %{
          uid: String.t(),
          integration_id: pos_integer(),
          linked_meeting: linked_meeting()
        }

  @type failure :: %{reason: term(), retry: :queued | :not_queued}

  @doc """
  Deletes `event` from its calendar on behalf of `user_id`, cancels the
  meeting it was booked as, and removes its cached row.

  The event is addressed by its `:provider_event_id` when it has one, and by
  its iCal UID otherwise.

  Returns `{:ok, deleted}`, or `{:error, %{reason: reason, retry: :queued |
  :not_queued}}` where `:queued` means the delete will be replayed on the
  next sync.
  """
  @spec delete_event(pos_integer(), event()) :: {:ok, deleted()} | {:error, failure()}
  def delete_event(user_id, event) do
    case ensure_deletable(stored_event(event)) do
      :ok -> delete_single_event(user_id, event)
      {:error, reason} -> {:error, %{reason: reason, retry: :not_queued}}
    end
  end

  @doc """
  Whether `event` may be deleted from the grid: a single event may, anything
  that belongs to a series may not. The series test is the one a move uses,
  see `Tymeslot.CalendarGrid.EventMove.ensure_movable/1`.
  """
  @spec ensure_deletable(map()) :: :ok | {:error, :recurring_event}
  defdelegate ensure_deletable(event), to: EventMove, as: :ensure_movable

  defp stored_event(%{uid: uid, calendar_integration_id: integration_id} = event) do
    case ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:ok, record} -> record
      {:error, :not_found} -> event
    end
  end

  defp delete_single_event(user_id, %{uid: uid, calendar_integration_id: integration_id} = event) do
    provider_event_id = Map.get(event, :provider_event_id)

    # Both halves of the event's address: its own id, and the calendar it is
    # on. Without the calendar a Google or Outlook delete could only address
    # the integration's default booking calendar, so deleting an event on any
    # other one 404'd.
    opts =
      Enum.reject(
        [
          provider_event_id: provider_event_id,
          calendar_id: Map.get(event, :provider_calendar_id)
        ],
        fn {_key, value} -> is_nil(value) end
      )

    case CalendarEvents.delete_event_and_reconcile(
           uid,
           provider_event_id,
           {integration_id, user_id},
           opts
         ) do
      {:ok, result} ->
        purge_local_traces(user_id, event)
        {:ok, %{uid: uid, integration_id: integration_id, linked_meeting: linked_meeting(result)}}

      {:error, reason} ->
        {:error, %{reason: reason, retry: queue_retry(event, reason)}}
    end
  end

  # Every step runs after the event has already gone from the calendar, so none
  # of them may turn a delete that happened into one the organiser is told to
  # retry. A cached row that outlives its event is removed by the next sync
  # anyway, a video room left behind falls due to the nightly expiry scan, and
  # a stale availability entry expires on its own; a message telling the
  # organiser to delete an event that no longer exists does not recover. They
  # are rescued one by one so a failing room clean-up still leaves the cached
  # row deleted and the availability invalidated.
  defp purge_local_traces(user_id, %{uid: uid, calendar_integration_id: integration_id} = event) do
    context = [user_id: user_id, calendar_integration_id: integration_id, uid: uid]

    after_delete("delete the event's video rooms", context, fn ->
      :ok = EventVideoRooms.event_deleted(event)
    end)

    after_delete("delete the cached event row", context, fn ->
      {:ok, _deleted_or_missing} = ProviderCalendarEventQueries.delete_by_uid(integration_id, uid)
    end)

    after_delete("invalidate cached availability", context, fn ->
      AvailabilityCache.invalidate_for_user(user_id)
    end)
  end

  defp after_delete(step, context, fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error(
        "Calendar grid delete: local cleanup failed after the event was deleted",
        [step: step, error: Exception.format(:error, error, __STACKTRACE__)] ++ context
      )

      :ok
  end

  defp linked_meeting(%{meeting_attendee_email: _email, reconcile_result: :ok}), do: :cancelled

  defp linked_meeting(%{meeting_attendee_email: _email, reconcile_result: {:error, _reason}}),
    do: :cancel_failed

  defp linked_meeting(_result), do: :none

  # A queued delete has not reached the calendar yet: the event is still on
  # the server and the grid puts it back. The organiser's availability is
  # therefore left alone until the delete actually lands, so a slot the event
  # still occupies is not offered to bookers in the meantime.
  defp queue_retry(%{uid: uid, calendar_integration_id: integration_id}, reason) do
    target = %{uid: uid, calendar_integration_id: integration_id}

    with true <- CalendarEvents.queueable_error?(reason),
         :ok <- CalendarEvents.queue_for_offline_retry(target, :delete, %{}) do
      :queued
    else
      _not_queued -> :not_queued
    end
  end
end
