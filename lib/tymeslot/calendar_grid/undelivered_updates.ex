defmodule Tymeslot.CalendarGrid.UndeliveredUpdates do
  @moduledoc """
  The guests of a dashboard calendar event whose latest update email could
  not be delivered, shown to the organiser on the event so they can tell the
  guest another way.

  The update email job notes each guest's outcome as it goes
  (`note_delivery/4`): a failure records the guest, a delivery clears them.
  A failure is recorded as it happens, not only once the job's retries run
  out, so the organiser learns of an outage while it lasts; a retry that gets
  through clears it again. Recording is an upsert on the guest of the event,
  so a retried or rescued job leaves one record, not one per attempt. A guest
  still failing when the job gives up stays recorded until a later update
  reaches them or the organiser dismisses the notice (`dismiss/3`).

  The event is addressed by its integration and the uid of its cached row,
  as the update email job names it.
  """

  require Logger

  alias Tymeslot.CalendarGrid.UndeliveredUpdateQueries
  alias Tymeslot.Clock

  @doc """
  Notes the outcome of one guest's update email: a success (`:ok` or
  `{:ok, _}`) clears any failure recorded for them, anything else records
  one. For the email job, which acts for the system, so it is unscoped.
  """
  @spec note_delivery(pos_integer(), String.t(), String.t(), term()) :: :ok
  def note_delivery(integration_id, event_uid, email, :ok),
    do: clear(integration_id, event_uid, email)

  def note_delivery(integration_id, event_uid, email, {:ok, _result}),
    do: clear(integration_id, event_uid, email)

  def note_delivery(integration_id, event_uid, email, _failure) do
    failed_at = DateTime.truncate(Clock.utc_now(), :second)

    case UndeliveredUpdateQueries.upsert(integration_id, event_uid, email, failed_at) do
      {:ok, _record} ->
        :ok

      # The integration went while the email was being sent; there is no
      # event left to show the failure on.
      {:error, _changeset} ->
        Logger.info("Undelivered update not recorded, the integration is gone",
          integration_id: integration_id,
          event_uid: event_uid
        )

        :ok
    end
  end

  @doc """
  The addresses of the event's guests whose latest update email could not be
  delivered. Empty for an integration `user_id` does not own.
  """
  @spec list_for_event(pos_integer(), pos_integer(), String.t()) :: [String.t()]
  def list_for_event(user_id, integration_id, event_uid),
    do: UndeliveredUpdateQueries.list_emails_for_owner(user_id, integration_id, event_uid)

  @doc """
  Clears the event's undelivered-update notice: the organiser has seen it.
  Touches nothing on an integration `user_id` does not own.
  """
  @spec dismiss(pos_integer(), pos_integer(), String.t()) :: :ok
  def dismiss(user_id, integration_id, event_uid) do
    UndeliveredUpdateQueries.delete_for_owner(user_id, integration_id, event_uid)
    :ok
  end

  @doc """
  Forgets the notices of the events `event_uids` of the integration, once
  they are deleted: nothing is left to show them on. Touches nothing on an
  integration `user_id` does not own.
  """
  @spec events_deleted(pos_integer(), pos_integer(), [String.t()]) :: :ok
  def events_deleted(user_id, integration_id, event_uids) do
    UndeliveredUpdateQueries.delete_events_for_owner(user_id, integration_id, event_uids)
    :ok
  end

  @doc """
  Moves each event's notices to the uid its occurrence is cached under
  after a write that rewrote its series, as
  `Tymeslot.CalendarGrid.SeriesCarry` works it out: `moves` pairs each
  `{integration_id, event_uid}` with its successor, or `nil` for an
  occurrence with none, whose notices are forgotten. Touches nothing on an
  integration `user_id` does not own.
  """
  @spec series_rewritten(
          pos_integer(),
          [{{pos_integer(), String.t()}, {pos_integer(), String.t()} | nil}]
        ) :: :ok
  def series_rewritten(user_id, moves) do
    UndeliveredUpdateQueries.move_for_owner(user_id, moves)
    :ok
  end

  defp clear(integration_id, event_uid, email) do
    UndeliveredUpdateQueries.delete(integration_id, event_uid, email)
    :ok
  end
end
