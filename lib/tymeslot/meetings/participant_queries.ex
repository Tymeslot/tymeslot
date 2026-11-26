defmodule Tymeslot.Meetings.ParticipantQueries do
  @moduledoc """
  Database queries for the `meeting_participants` table.

  Pure data access only — seat arithmetic and the traffic-light thresholds
  live in `Tymeslot.Meetings.Seats`; booking rules live in the booking flow.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Meetings.GuestSchema, as: Guest
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token

  @doc "Inserts a participant for a meeting."
  @spec insert(map()) :: {:ok, Participant.t()} | {:error, Changeset.t()}
  def insert(attrs) when is_map(attrs) do
    %Participant{}
    |> Participant.creation_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetches a participant by their management token, looked up by its hash."
  @spec get_by_token(String.t()) :: {:ok, Participant.t()} | {:error, :not_found}
  def get_by_token(token) when is_binary(token) do
    case Repo.get_by(Participant, management_token_hash: Token.hash_token(token)) do
      nil -> {:error, :not_found}
      participant -> {:ok, participant}
    end
  end

  @doc "Fetches a participant by primary key."
  @spec get(binary()) :: {:ok, Participant.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(Participant, id) do
      nil -> {:error, :not_found}
      participant -> {:ok, participant}
    end
  end

  @doc """
  Lists the live (not cancelled) participants of a meeting, oldest first.
  Visible: excludes seats awaiting email verification.
  """
  @spec list_live_for_meeting(binary()) :: [Participant.t()]
  def list_live_for_meeting(meeting_id) do
    meeting_id
    |> live_for_meeting()
    |> where_visible()
    |> Repo.all()
  end

  @doc """
  Lists the live participants of a meeting, oldest first. Held: includes
  seats awaiting email verification, for the booker finding their own seat.
  """
  @spec list_live_held_for_meeting(binary()) :: [Participant.t()]
  def list_live_held_for_meeting(meeting_id) do
    meeting_id
    |> live_for_meeting()
    |> Repo.all()
  end

  defp live_for_meeting(meeting_id) do
    Participant
    |> where([p], p.meeting_id == ^meeting_id and is_nil(p.cancelled_at))
    |> order_by([p], asc: p.inserted_at, asc: p.id)
  end

  @doc """
  The ids among `meeting_ids` of the meetings `email` holds a live seat in,
  matched case-insensitively as the seat's unique index matches it.
  """
  @spec meeting_ids_seating(String.t(), [binary()]) :: MapSet.t(binary())
  def meeting_ids_seating(_email, []), do: MapSet.new()

  def meeting_ids_seating(email, meeting_ids) when is_binary(email) and is_list(meeting_ids) do
    from(p in Participant,
      where:
        p.meeting_id in ^meeting_ids and is_nil(p.cancelled_at) and
          fragment("lower(?)", p.email) == ^String.downcase(email),
      select: p.meeting_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Whether `email` holds a live seat on the meeting, matched
  case-insensitively as `meeting_participants_live_email_index` matches it.
  """
  @spec live_email_taken?(binary(), String.t()) :: boolean()
  def live_email_taken?(meeting_id, email) when is_binary(meeting_id) and is_binary(email) do
    Participant
    |> where([p], p.meeting_id == ^meeting_id and is_nil(p.cancelled_at))
    |> where([p], fragment("lower(?)", p.email) == fragment("lower(?)", ^email))
    |> Repo.exists?()
  end

  @doc """
  Soft-cancels a participant by stamping `cancelled_at` (defaults to now).
  """
  @spec cancel(Participant.t(), DateTime.t()) ::
          {:ok, Participant.t()} | {:error, Changeset.t()}
  def cancel(%Participant{} = participant, cancelled_at \\ DateTime.utc_now(:second)) do
    participant
    |> Participant.cancel_changeset(cancelled_at)
    |> Repo.update()
  end

  @doc """
  Stamps `confirmation_sent_at` (the participant's own confirmation went out),
  unless an earlier run already did. Returns `:ok` either way.
  """
  @spec mark_confirmation_sent(Participant.t()) :: :ok
  def mark_confirmation_sent(%Participant{id: id}), do: stamp_once(id, :confirmation_sent_at)

  @doc """
  Stamps `organizer_notified_at` (the organiser was told about this seat),
  unless an earlier run already did. Returns `:ok` either way.
  """
  @spec mark_organizer_notified(Participant.t()) :: :ok
  def mark_organizer_notified(%Participant{id: id}), do: stamp_once(id, :organizer_notified_at)

  defp stamp_once(id, field) do
    now = DateTime.utc_now(:second)

    Participant
    |> where([p], p.id == ^id and is_nil(field(p, ^field)))
    |> Repo.update_all(set: [{field, now}, {:updated_at, now}])

    :ok
  end

  @doc """
  Advances the calendar revision of every live seat on a meeting, for an
  update to the entry each of them holds (the host moved the meeting).
  """
  @spec bump_ical_sequence_for_meeting(binary()) :: non_neg_integer()
  def bump_ical_sequence_for_meeting(meeting_id) do
    {count, _rows} =
      Participant
      |> where([p], p.meeting_id == ^meeting_id and is_nil(p.cancelled_at))
      |> Repo.update_all(inc: [ical_sequence: 1])

    count
  end

  @doc """
  Records a change to the meeting's end on every live participant's seat.

  Each seat is its own calendar entry, so the change is a new revision of
  every live seat's entry too: its `ical_sequence` advances by one. A seat
  with no end change pending keeps `previous_end`, the end it knew, as its
  `notified_end_time`; one already pending keeps the end it was last told.
  """
  @spec record_end_change(String.t(), DateTime.t()) :: non_neg_integer()
  def record_end_change(meeting_id, %DateTime{} = previous_end) do
    {count, _rows} =
      Participant
      |> where([p], p.meeting_id == ^meeting_id and is_nil(p.cancelled_at))
      |> update([p],
        set: [notified_end_time: fragment("COALESCE(?, ?)", p.notified_end_time, ^previous_end)],
        inc: [ical_sequence: 1]
      )
      |> Repo.update_all([])

    count
  end

  @doc "Records that the participant has been told the meeting ends at `end_time`."
  @spec put_notified_end(String.t(), DateTime.t()) :: :ok
  def put_notified_end(participant_id, %DateTime{} = end_time) do
    Participant
    |> where([p], p.id == ^participant_id)
    |> Repo.update_all(set: [notified_end_time: end_time])

    :ok
  end

  @doc """
  Counts the live (not cancelled) participants of a meeting. Visible:
  excludes seats awaiting email verification.
  """
  @spec count_live_for_meeting(binary()) :: non_neg_integer()
  def count_live_for_meeting(meeting_id) do
    Participant
    |> where([p], p.meeting_id == ^meeting_id and is_nil(p.cancelled_at))
    |> where_visible()
    |> select([p], count(p.id))
    |> Repo.one()
  end

  @doc """
  Counts the live (not cancelled) participants of a meeting. Held: includes
  seats awaiting email verification, each of which still occupies the slot.
  """
  @spec count_live_held_for_meeting(binary()) :: non_neg_integer()
  def count_live_held_for_meeting(meeting_id) do
    meeting_id
    |> live_for_meeting()
    |> exclude(:order_by)
    |> select([p], count(p.id))
    |> Repo.one()
  end

  @doc """
  The latest verification deadline among a meeting's seats still awaiting
  email verification, or `nil` when no seat on it is held.
  """
  @spec latest_held_deadline(binary()) :: DateTime.t() | nil
  def latest_held_deadline(meeting_id) do
    Participant
    |> where([p], p.meeting_id == ^meeting_id)
    |> live_unverified()
    |> select([p], max(p.verification_deadline_at))
    |> Repo.one()
  end

  @doc """
  Counts the seats taken on a meeting: live participants plus their guests,
  except guests who declined, whose seats are free again. Visible: excludes
  seats awaiting email verification.
  """
  @spec count_seats_taken(binary()) :: non_neg_integer()
  def count_seats_taken(meeting_id) do
    meeting_id |> seats_query() |> where_visible() |> Repo.one()
  end

  @doc """
  `count_seats_taken/1`'s count including seats awaiting email verification.
  Held: what a meeting's capacity is measured against.
  """
  @spec count_seats_held(binary()) :: non_neg_integer()
  def count_seats_held(meeting_id) do
    meeting_id |> seats_query() |> Repo.one()
  end

  defp seats_query(meeting_id) do
    from(p in Participant,
      left_join: g in Guest,
      on: g.participant_id == p.id and g.status != :declined,
      where: p.meeting_id == ^meeting_id and is_nil(p.cancelled_at),
      select: count(p.id, :distinct) + count(g.id)
    )
  end

  @doc """
  Live participants and seats taken (`count_seats_taken/1`'s count) on each
  of `meeting_ids`, in one grouped query. A meeting without live
  participants does not appear in the result. Visible: excludes seats
  awaiting email verification.
  """
  @spec counts_by_meeting([binary()]) :: %{
          binary() => %{participants: non_neg_integer(), seats_taken: non_neg_integer()}
        }
  def counts_by_meeting([]), do: %{}

  def counts_by_meeting(meeting_ids) when is_list(meeting_ids) do
    meeting_ids |> counts_query() |> where_visible() |> run_counts()
  end

  @doc """
  `counts_by_meeting/1` including seats awaiting email verification. Held:
  what each meeting's capacity is measured against.
  """
  @spec held_counts_by_meeting([binary()]) :: %{
          binary() => %{participants: non_neg_integer(), seats_taken: non_neg_integer()}
        }
  def held_counts_by_meeting([]), do: %{}

  def held_counts_by_meeting(meeting_ids) when is_list(meeting_ids) do
    meeting_ids |> counts_query() |> run_counts()
  end

  defp counts_query(meeting_ids) do
    from(p in Participant,
      left_join: g in Guest,
      on: g.participant_id == p.id and g.status != :declined,
      where: p.meeting_id in ^meeting_ids and is_nil(p.cancelled_at),
      group_by: p.meeting_id,
      select: {p.meeting_id, count(p.id, :distinct), count(p.id, :distinct) + count(g.id)}
    )
  end

  defp run_counts(query) do
    query
    |> Repo.all()
    |> Map.new(fn {id, participants, seats} ->
      {id, %{participants: participants, seats_taken: seats}}
    end)
  end

  @doc """
  Seats taken per meeting start time for live meetings of a meeting type
  whose `start_time` falls in `[from_utc, to_utc)`, counted as
  `count_seats_held/1` does. Held: includes seats awaiting email
  verification, since this is the public capacity. One grouped query over meetings, participants
  and guests; meetings without live participants do not appear in the
  result.

  Composed through `MeetingState.where_slot_live/1` — the same "live slot"
  definition `GroupMeetingQueries.list_live_for_type_in_range/3` uses — so a
  meeting under a pending organizer reschedule request (its slot voided,
  its calendar event already deleted) drops out of the seat count exactly
  as it drops out of the availability overlay.
  """
  @spec seat_counts_for_range(integer(), DateTime.t(), DateTime.t()) ::
          %{DateTime.t() => non_neg_integer()}
  def seat_counts_for_range(meeting_type_id, from_utc, to_utc) do
    Meeting
    |> MeetingState.where_slot_live()
    |> where([m], m.meeting_type_id == ^meeting_type_id)
    |> where([m], m.start_time >= ^from_utc and m.start_time < ^to_utc)
    |> join(:inner, [m], p in Participant, on: p.meeting_id == m.id and is_nil(p.cancelled_at))
    |> join(:left, [m, p], g in Guest, on: g.participant_id == p.id and g.status != :declined)
    |> group_by([m], m.start_time)
    |> select([m, p, g], {m.start_time, count(p.id, :distinct) + count(g.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Restricts a query on the participant binding to the seats others may see:
  ungated ones and ones whose booker has verified their address.
  """
  @spec where_visible(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_visible(query) do
    where(query, [p], is_nil(p.verification_deadline_at) or not is_nil(p.email_verified_at))
  end

  @doc """
  Marks a held seat verified. Guarded in the `WHERE`, so a seat already
  verified, cancelled or never gated is left alone and reported as an error.
  """
  @spec transition_from_unverified(binary(), DateTime.t()) ::
          {:ok, Participant.t()} | {:error, :not_awaiting_verification}
  def transition_from_unverified(participant_id, %DateTime{} = now) do
    participant_id
    |> unverified_by_id()
    |> update([p], set: [email_verified_at: ^now])
    |> run_guarded()
  end

  @doc """
  Cancels a held seat that was never verified, advancing `ical_sequence` as
  `cancel/2` does. Guarded like `transition_from_unverified/2`.
  """
  @spec cancel_unverified(binary(), DateTime.t()) ::
          {:ok, Participant.t()} | {:error, :not_awaiting_verification}
  def cancel_unverified(participant_id, %DateTime{} = now) do
    participant_id
    |> unverified_by_id()
    |> update([p], set: [cancelled_at: ^now], inc: [ical_sequence: 1])
    |> run_guarded()
  end

  @doc """
  Counts one more verification email for a held seat, atomically, while it
  is live, unverified, its deadline is ahead of `now` and fewer than
  `max_sends` emails have gone out (`nil` counts as the one sent with the
  booking). The seat analogue of
  `Tymeslot.Meetings.MeetingTransitionQueries.count_verification_email/3`.
  """
  @spec count_verification_email(binary(), DateTime.t(), pos_integer()) ::
          {:ok, Participant.t()} | {:error, :refused}
  def count_verification_email(participant_id, %DateTime{} = now, max_sends)
      when is_integer(max_sends) do
    query =
      participant_id
      |> unverified_by_id()
      |> where(
        [p],
        p.verification_deadline_at > ^now and
          coalesce(p.verification_emails_sent, 1) < ^max_sends
      )
      |> select([p], p)
      |> update([p],
        set: [
          verification_emails_sent: fragment("COALESCE(?, 1) + 1", p.verification_emails_sent),
          updated_at: ^DateTime.truncate(now, :second)
        ]
      )

    case Repo.update_all(query, []) do
      {1, [participant]} -> {:ok, participant}
      {0, _none} -> {:error, :refused}
    end
  end

  @doc "Cancels every live unverified seat on a meeting, returning their ids."
  @spec cancel_unverified_for_meeting(binary(), DateTime.t()) :: {non_neg_integer(), [binary()]}
  def cancel_unverified_for_meeting(meeting_id, %DateTime{} = now) do
    Participant
    |> where([p], p.meeting_id == ^meeting_id)
    |> live_unverified()
    |> select([p], p.id)
    |> update([p], set: [cancelled_at: ^now], inc: [ical_sequence: 1])
    |> Repo.update_all([])
  end

  @doc """
  Lists live unverified seats whose hold has lapsed at `now`, oldest deadline
  first, with their meeting preloaded.
  """
  @spec list_expired_verifications(DateTime.t(), pos_integer()) :: [Participant.t()]
  def list_expired_verifications(%DateTime{} = now, limit) do
    Participant
    |> live_unverified()
    |> where([p], p.verification_deadline_at <= ^now)
    |> order_by([p], asc: p.verification_deadline_at, asc: p.id)
    |> limit(^limit)
    |> preload(:meeting)
    |> Repo.all()
  end

  @doc """
  Deletes the seats cancelled without ever being verified whose verification
  deadline is before `cutoff`. Their guests cascade. A seat verified and
  cancelled later has `email_verified_at` set and is never touched.
  """
  @spec delete_unverified_cancelled_before(DateTime.t()) :: {non_neg_integer(), nil}
  def delete_unverified_cancelled_before(%DateTime{} = cutoff) do
    Participant
    |> where(
      [p],
      not is_nil(p.cancelled_at) and is_nil(p.email_verified_at) and
        not is_nil(p.verification_deadline_at) and p.verification_deadline_at < ^cutoff
    )
    |> Repo.delete_all()
  end

  defp unverified_by_id(participant_id) do
    Participant
    |> where([p], p.id == ^participant_id)
    |> live_unverified()
  end

  defp live_unverified(query) do
    where(
      query,
      [p],
      is_nil(p.cancelled_at) and is_nil(p.email_verified_at) and
        not is_nil(p.verification_deadline_at)
    )
  end

  defp run_guarded(query) do
    case query |> select([p], p) |> Repo.update_all([]) do
      {1, [participant]} -> {:ok, participant}
      {0, _none} -> {:error, :not_awaiting_verification}
    end
  end
end
