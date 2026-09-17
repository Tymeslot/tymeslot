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

  ## Failure

  A failed delete is queued for replay on the next sync when the error is one
  a retry can recover (see `Calendar.Events.queueable_error?/1`) and the
  integration has an offline queue (the CalDAV family). The queue marks the
  cached row `locally_deleted`, and the replay removes it once the server has
  deleted the event.
  """

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
  def delete_event(user_id, %{uid: uid, calendar_integration_id: integration_id} = event) do
    provider_event_id = Map.get(event, :provider_event_id)
    opts = if provider_event_id, do: [provider_event_id: provider_event_id], else: []

    case CalendarEvents.delete_event_and_reconcile(
           uid,
           provider_event_id,
           {integration_id, user_id},
           opts
         ) do
      {:ok, result} ->
        :ok = EventVideoRooms.event_deleted(event)

        {:ok, _deleted_or_missing} =
          ProviderCalendarEventQueries.delete_by_uid(integration_id, uid)

        AvailabilityCache.invalidate_for_user(user_id)
        {:ok, %{uid: uid, integration_id: integration_id, linked_meeting: linked_meeting(result)}}

      {:error, reason} ->
        {:error, %{reason: reason, retry: queue_retry(event, reason)}}
    end
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
