defmodule Tymeslot.Meetings.SeatHolds do
  @moduledoc """
  Seats held for a booker who is paying for them (`SeatHoldSchema`).

  A hold counts against its meeting's capacity, guests included, from the
  moment it is created until it is converted into a participant or released.
  It is counted wherever seats are counted (`Tymeslot.Meetings.Seats`) and
  nowhere else: it is no participant, so it is never listed, emailed or put
  in a calendar. Lapsed holds (`expires_at` in the past) still count until
  they are released.

  Holds are created only by `GroupScheduling.book_seat/3` with its `:hold`
  option, under the same locks as a participant, so there is no public
  insert here.

  `topic/1` and `broadcast/2` carry a hold's payment outcome to the page
  waiting on it: `{:paid, participant_id}` once it converted, `:expired` once
  it was released. Broadcast only after the change has committed.
  """

  alias Tymeslot.Clock
  alias Tymeslot.Meetings.SeatHoldQueries
  alias Tymeslot.Meetings.SeatHoldSchema

  @type broadcast_message :: {:paid, binary()} | :expired

  @overdue_grace_seconds 5 * 60

  @doc """
  Fetches a hold by id. Unscoped: for system callers (the payment webhook,
  the expiry worker) and the booker's own payment page, which reaches the
  hold through its payment, never for a host acting on their account.
  """
  @spec get(binary()) :: SeatHoldSchema.t() | nil
  defdelegate get(id), to: SeatHoldQueries

  @doc "Seats held on a meeting."
  @spec seats_held(binary()) :: non_neg_integer()
  defdelegate seats_held(meeting_id), to: SeatHoldQueries

  @doc "Seats held on each of `meeting_ids`; a meeting without holds is absent."
  @spec seats_held_by_meeting([binary()]) :: %{binary() => non_neg_integer()}
  defdelegate seats_held_by_meeting(meeting_ids), to: SeatHoldQueries

  @doc """
  Seats held per start time on the live meetings of `meeting_type_id`
  starting in `[from_utc, to_utc)`; a slot without holds is absent.
  """
  @spec seats_held_for_range(integer(), DateTime.t(), DateTime.t()) ::
          %{DateTime.t() => non_neg_integer()}
  defdelegate seats_held_for_range(meeting_type_id, from_utc, to_utc), to: SeatHoldQueries

  @doc "The holds still `held` on a meeting, oldest first."
  @spec list_held_for_meeting(binary()) :: [SeatHoldSchema.t()]
  defdelegate list_held_for_meeting(meeting_id), to: SeatHoldQueries

  @doc """
  The moment before which a hold still `held` has overrun its window: its
  `expires_at` plus a grace for the expiry webhook still on its way. Such
  a hold's payment outcome never reached it; the sweeper settles it
  (`Tymeslot.Meetings.Workers.ExpireSeatHolds`), and it no longer stands
  for an open checkout.
  """
  @spec overdue_cutoff(DateTime.t()) :: DateTime.t()
  def overdue_cutoff(%DateTime{} = now) do
    now
    |> DateTime.add(-@overdue_grace_seconds, :second)
    |> DateTime.truncate(:second)
  end

  @doc """
  Up to `limit` holds still `held` past `cutoff` (`overdue_cutoff/1`): holds whose payment
  outcome never reached them, those a sweep looked at least recently
  (`mark_swept/1`) first.
  """
  @spec list_overdue(DateTime.t(), pos_integer()) :: [SeatHoldSchema.t()]
  defdelegate list_overdue(cutoff, limit), to: SeatHoldQueries

  @doc """
  Records that a sweep looked at the hold `id` and left it held, so the
  next sweep reaches the holds behind it first.
  """
  @spec mark_swept(binary()) :: :ok
  defdelegate mark_swept(id), to: SeatHoldQueries, as: :touch

  @doc """
  Releases a hold that is still `held`, freeing its seats.

  One conditional update, so of two racing callers (an expiry and a
  conversion) exactly one wins; a hold no longer held is left as it is and
  `{:ok, :unchanged}` returned. It neither locks the meeting nor changes its
  status, and broadcasts nothing: the caller announces the release once its
  transaction has committed.

  The update locks the hold's row. A caller that will also lock the hold's
  meeting must lock the meeting first and release after, so that every
  writer takes the locks in one order: payment row, then the host's
  schedule lock (`MeetingConflictQueries.lock_organizer_schedule/1`), then
  the meeting row, then the hold.
  """
  @spec release(SeatHoldSchema.t(), SeatHoldSchema.release_reason()) ::
          {:ok, SeatHoldSchema.t()} | {:ok, :unchanged}
  def release(%SeatHoldSchema{id: id}, reason) do
    case SeatHoldQueries.release(id, reason) do
      %SeatHoldSchema{} = released -> {:ok, released}
      nil -> {:ok, :unchanged}
    end
  end

  @doc """
  Releases every hold still `held` on the meeting `meeting_id` for
  `reason`, returning the holds it released. Inside the caller's
  transaction, which must already hold the meeting's row lock (the lock
  order of `release/2`). Broadcasts nothing; the caller announces each
  release once committed.
  """
  @spec release_open_for_meeting(binary(), SeatHoldSchema.release_reason()) ::
          [SeatHoldSchema.t()]
  defdelegate release_open_for_meeting(meeting_id, reason),
    to: SeatHoldQueries,
    as: :release_held_for_meeting

  @doc """
  Moves the holds still `held` on the meeting `meeting_id` to its new
  `start_time`, so a hold converting later finds the slot its meeting is
  now at. Inside the transaction moving the meeting.
  """
  @spec follow_moved_meeting(binary(), DateTime.t()) :: non_neg_integer()
  defdelegate follow_moved_meeting(meeting_id, start_time),
    to: SeatHoldQueries,
    as: :restamp_held_for_meeting

  @doc """
  Deletes the holds that settled (converted or released) more than `days`
  days ago, with the booker's details they snapshot, returning
  `{deleted_count, nil}`. A hold still `held` is never deleted by age.
  Deleting a hold leaves its payment, whose `seat_hold_id` is nilified.
  Called by `Tymeslot.Workers.DataRetentionWorker`.
  """
  @spec prune_settled(non_neg_integer()) :: {non_neg_integer(), nil}
  def prune_settled(days) when is_integer(days) and days >= 0 do
    cutoff = DateTime.add(Clock.utc_now(), -days * 86_400, :second)
    SeatHoldQueries.delete_settled_before(cutoff)
  end

  @doc "The PubSub topic carrying a hold's payment outcome."
  @spec topic(binary()) :: String.t()
  def topic(hold_id) when is_binary(hold_id), do: "seat_hold_payment:" <> hold_id

  @doc "Broadcasts a hold's payment outcome on `topic/1`. Call after commit."
  @spec broadcast(binary(), broadcast_message()) :: :ok | {:error, term()}
  def broadcast(hold_id, {:paid, participant_id} = message) when is_binary(participant_id),
    do: Phoenix.PubSub.broadcast(Tymeslot.PubSub, topic(hold_id), message)

  def broadcast(hold_id, :expired = message),
    do: Phoenix.PubSub.broadcast(Tymeslot.PubSub, topic(hold_id), message)
end
