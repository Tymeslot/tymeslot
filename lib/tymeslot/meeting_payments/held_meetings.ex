defmodule Tymeslot.MeetingPayments.HeldMeetings do
  @moduledoc """
  A booking that is waiting for payment holds its slot: its meeting sits in
  `awaiting_payment` until the checkout completes or the hold is released.
  This module is the one place that releases such a hold and tells the
  waiting attendee about it, whichever path released it (a Stripe event, a
  host disconnecting Stripe, an account frozen pending deletion).

  Releasing is two steps, split around the caller's transaction:

    * `expire/1` runs inside it, after the caller has locked or claimed the
      booking payment, so locks are always taken payment first, then meeting.
    * `announce_expired/1` runs once that transaction has committed, never on
      rollback: it releases the cached availability offer and broadcasts
      `:expired` on `topic/1`.

  `topic/1` is the PubSub topic every payment status broadcast and every
  subscriber uses. Subscribers receive the bare atoms `:paid` and `:expired`.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState

  @type status_message :: :paid | :expired

  @doc "The PubSub topic carrying payment status changes for a meeting."
  @spec topic(String.t()) :: String.t()
  def topic(meeting_id), do: "meeting_payment:#{meeting_id}"

  @doc """
  Broadcasts a payment status change (`:paid` or `:expired`) for a meeting.
  Call it after the change has committed.
  """
  @spec broadcast(String.t(), status_message()) :: :ok | {:error, term()}
  def broadcast(meeting_id, message) when message in [:paid, :expired] do
    Phoenix.PubSub.broadcast(Tymeslot.PubSub, topic(meeting_id), message)
  end

  @doc """
  Expires the meeting with `meeting_id` if it is still awaiting payment.

  Must run inside the caller's transaction, after the booking payment has
  been locked or claimed: the meeting row is locked here and its status is
  read from the locked row, so a confirmation committed meanwhile is seen
  rather than overwritten.

  Returns `{:ok, :expired, meeting}` with the updated meeting, to be passed
  to `announce_expired/1` after commit; `{:ok, :unchanged}` when there is no
  such meeting or it is no longer awaiting payment; or `{:error, changeset}`
  when the write fails.
  """
  @spec expire(String.t() | nil) ::
          {:ok, :expired, MeetingSchema.t()} | {:ok, :unchanged} | {:error, Ecto.Changeset.t()}
  def expire(nil), do: {:ok, :unchanged}

  def expire(meeting_id) do
    with {:ok, meeting} <- MeetingQueries.get_meeting_for_update(meeting_id),
         true <- MeetingState.awaiting_payment?(meeting) do
      # A status write only, so a row whose other fields fail today's full
      # validation is still expired.
      case MeetingQueries.update_meeting_status(meeting, %{status: "expired"}) do
        {:ok, expired} -> {:ok, :expired, expired}
        {:error, _changeset} = error -> error
      end
    else
      _not_held -> {:ok, :unchanged}
    end
  end

  @doc """
  Announces a released hold once its transaction has committed: the booking
  page stops treating the slot as taken, and the attendee waiting on the
  payment is told the booking expired.
  """
  @spec announce_expired(MeetingSchema.t()) :: :ok
  def announce_expired(%MeetingSchema{id: meeting_id, organizer_user_id: organizer_user_id}) do
    Availability.changed(organizer_user_id)
    broadcast(meeting_id, :expired)
    :ok
  end
end
