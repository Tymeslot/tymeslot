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

  A paid series holds every session on its one payment, and releases them
  together (`expire_series/1`). Its pages wait on the first session's topic
  (the checkout returns there), so a series is announced once, through its
  first session.
  """

  alias Tymeslot.Availability
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo

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
      case MeetingQueries.update_meeting_status(meeting, %{status: :expired}) do
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

  @doc """
  Expires every session of a paid series still awaiting payment.

  Locks the series row, then its meetings in series order
  (`SeriesQueries.lock_meetings/1`), the order every writer of a series
  takes them in, after the booking payment where the caller holds it.
  Joins the caller's transaction, or opens its own.

  Returns `{:ok, :expired, first}` with the series' first session (as it
  now stands), to be passed to `announce_expired/1` once committed, which
  releases the organiser's availability once and tells the page waiting on
  that session; `{:ok, :unchanged, first_id}` when no session was awaiting
  payment (`first_id` nil for a series with no meetings left); or
  `{:error, reason}` when a write fails.
  """
  @spec expire_series(SeriesSchema.t() | binary() | nil) ::
          {:ok, :expired, MeetingSchema.t()}
          | {:ok, :unchanged, String.t() | nil}
          | {:error, term()}
  def expire_series(nil), do: {:ok, :unchanged, nil}
  def expire_series(%SeriesSchema{id: id}), do: expire_series(id)

  def expire_series(series_id) when is_binary(series_id) do
    result =
      Repo.transaction(fn ->
        {_series, meetings} = lock_series(series_id)
        Enum.map_reduce(meetings, false, &expire_member/2)
      end)

    case result do
      {:ok, {[first | _rest], true}} -> {:ok, :expired, first}
      {:ok, {[first | _rest], false}} -> {:ok, :unchanged, first.id}
      {:ok, {[], _expired?}} -> {:ok, :unchanged, nil}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The meetings a booking payment paid for, unlocked: its own meeting, or
  every session of its series in series order; `[]` when they are gone (the
  host's account deleted). The first is the one a payment's emails name
  and whose topic its pages wait on.
  """
  @spec meetings_for(map()) :: [MeetingSchema.t()]
  def meetings_for(%{series_id: series_id}) when is_binary(series_id),
    do: SeriesQueries.list_meetings(series_id)

  def meetings_for(%{meeting_id: meeting_id}) when is_binary(meeting_id) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} -> [meeting]
      {:error, _not_found} -> []
    end
  end

  def meetings_for(_payment), do: []

  @doc """
  Locks a series row, then its meetings in series order, and returns both
  (`{nil, []}` for a series that is gone). The one order every writer of a
  paid series takes its locks in, after the booking payment: two writers
  of one series then wait on each other instead of deadlocking. Call inside
  a transaction.
  """
  @spec lock_series(binary() | nil) :: {SeriesSchema.t() | nil, [MeetingSchema.t()]}
  def lock_series(nil), do: {nil, []}

  def lock_series(series_id) when is_binary(series_id) do
    case SeriesQueries.lock(series_id) do
      nil -> {nil, []}
      series -> {series, SeriesQueries.lock_meetings(series)}
    end
  end

  defp expire_member(meeting, expired?) do
    if MeetingState.awaiting_payment?(meeting) do
      case MeetingQueries.update_meeting_status(meeting, %{status: :expired}) do
        {:ok, expired} -> {expired, true}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    else
      {meeting, expired?}
    end
  end
end
