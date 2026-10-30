defmodule Tymeslot.Polls do
  @moduledoc """
  Context for meeting polls: creating polls with candidate slots, reading them
  for the host or for voting, tallying votes, and lifecycle transitions.
  """

  @behaviour Tymeslot.Security.EncryptedStorage

  alias Ecto.UUID
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Meetings
  alias Tymeslot.MeetingTypes

  alias Tymeslot.Polls.{
    Creation,
    Editing,
    HostReadiness,
    Invitations,
    MeetingTypeRule,
    OpenPollLock,
    PollParticipantQueries,
    PollParticipantSchema,
    PollQueries,
    PollSchema,
    Voting
  }

  alias Tymeslot.Security.EncryptedString

  @pubsub Tymeslot.PubSub
  @responses [:yes, :if_need_be, :no]

  # The voting links, the poll's and each participant's.
  @impl Tymeslot.Security.EncryptedStorage
  def encrypted_storage do
    for schema <- [PollSchema, PollParticipantSchema],
        do: {schema.__schema__(:source), EncryptedString.columns(schema)}
  end

  @doc """
  Creates a poll and all of its candidate slots in a single transaction.

  `attrs` carries `:title`, `:duration_minutes`, `:timezone`, and `:slots` (a
  list of `%{start_time: dt, end_time: dt}`; `end_time` may be omitted and then
  defaults to `start_time` plus the poll duration). `:description`,
  `:deadline_at`, and `:meeting_type_id` are optional, and so is `:invitees`,
  entries from `Tymeslot.Polls.Invitations.parse/1` invited with the poll and
  emailed once it is saved. Invitees past the host's poll email allowance
  refuse the whole poll with `{:error, {:rate_limited, remaining}}`; an invitee
  over their own limit is left out (see
  `Tymeslot.Polls.Invitations.uninvited/2`).

  `:invite_only` says whether only those invitees (and anyone invited later)
  can vote. Without it, the poll is invite-only exactly when it is created
  with invitees (`default_invite_only?/1`).

  When `:meeting_type_id` is given it is loaded scoped to `user_id`; the poll
  snapshots the type's name and duration unless those are given explicitly.

  A host without a calendar connected is refused with `{:error, :no_calendar}`:
  the voting page stays closed until they have one.
  """
  @spec create_poll(integer(), map()) ::
          {:ok, PollSchema.t()}
          | {:error,
             :meeting_type_not_found
             | :payment_required_type
             | :no_slots
             | :too_many_slots
             | :slot_in_past
             | :poll_full
             | :no_username
             | :no_calendar
             | {:rate_limited, non_neg_integer()}
             | Ecto.Changeset.t()}
  defdelegate create_poll(user_id, attrs), to: Creation

  @doc """
  Whether a new poll is invite-only when its host has not said: yes once they
  invite anyone with it. The dashboard presets its choice with this, so the
  form and `create_poll/2` agree.
  """
  @spec default_invite_only?([Invitations.entry()]) :: boolean()
  def default_invite_only?(invitees) when is_list(invitees), do: invitees != []

  @doc """
  The candidate `start_times` that would put a meeting of `duration_minutes`
  inside `user_id`'s time off, in the order given.

  Advisory: the poll form uses it to warn the host while they build the poll,
  and nothing refuses to save one. Confirmation is where time off is enforced
  (`Tymeslot.Polls.Confirm`), because a period can be entered after the poll
  has gone out.
  """
  @spec starts_during_time_off(integer(), [DateTime.t()], pos_integer()) :: [DateTime.t()]
  def starts_during_time_off(user_id, start_times, duration_minutes)
      when is_integer(duration_minutes) and duration_minutes > 0 do
    user_id
    |> TimeOff.clashing_ranges(
      Enum.map(start_times, &{&1, DateTime.add(&1, duration_minutes, :minute)})
    )
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Fetches a poll by its public token, in any status, for the voting page.

  Returns `{:error, :not_found}` while the poll's host is pending account
  deletion, like every other public page of that host.
  """
  @spec get_poll_for_voting(String.t()) :: {:ok, PollSchema.t()} | {:error, :not_found}
  def get_poll_for_voting(token) do
    case PollQueries.get_by_token(token) do
      nil -> {:error, :not_found}
      poll -> {:ok, poll}
    end
  end

  @doc "Fetches a poll by id scoped to its owner."
  @spec get_poll_for_host(Ecto.UUID.t(), integer()) ::
          {:ok, PollSchema.t()} | {:error, :not_found}
  def get_poll_for_host(id, user_id) do
    case PollQueries.get_for_user(id, user_id) do
      nil -> {:error, :not_found}
      poll -> {:ok, poll}
    end
  end

  @doc "Lists the user's polls, newest first."
  @spec list_polls(integer()) :: [PollSchema.t()]
  def list_polls(user_id), do: PollQueries.list_for_user(user_id)

  @doc """
  The host's meeting types a poll may take its title and length from: active
  ones that pass `Tymeslot.Polls.MeetingTypeRule`, so not a paid type nor a
  one-off event.
  """
  @spec meeting_types_for_poll(integer()) :: [Ecto.Schema.t()]
  def meeting_types_for_poll(user_id) do
    user_id
    |> MeetingTypes.get_active_meeting_types()
    |> Enum.filter(&match?({:ok, _meeting_type}, MeetingTypeRule.check(&1)))
  end

  @doc """
  Counts the user's polls that are still open for votes.
  """
  @spec count_open_polls(pos_integer()) :: non_neg_integer()
  def count_open_polls(user_id), do: PollQueries.count_open_for_user(user_id)

  @doc """
  Updates the user's open poll: its title and description, whether the host
  is emailed about new votes, who can vote (making it invite-only withdraws
  pending link requests), the voting deadline and the reminders before it,
  and adds a candidate time at each of `new_starts`. Existing times are never
  changed. See `Tymeslot.Polls.Editing`.

  Subscribers are notified, since the title, description, deadline and times
  are all on the public voting page.
  """
  @spec update_details(Ecto.UUID.t(), integer(), map(), [DateTime.t()]) ::
          {:ok, PollSchema.t()} | {:error, Editing.reason()}
  def update_details(id, user_id, attrs, new_starts \\ []),
    do: Editing.update(id, user_id, attrs, new_starts)

  @doc """
  Removes a participant from the user's open poll, with their responses, for
  someone the host does not want counted: a joke entry, or someone who has
  dropped out. Nobody is emailed about it.

  Written under the poll's row lock, like cancelling and editing, so a
  removal never lands on a poll confirmed in the meantime. Once the last
  invitee is gone the poll's reminders are cancelled, with nobody left to
  remind. If everyone still on the poll has voted, the host is nudged to
  pick a time, as the last vote would have done.

  An id that is not a participant of this poll, including one that is not a
  UUID at all, is `{:error, :not_found}`.
  """
  @spec remove_participant(Ecto.UUID.t(), integer(), String.t()) ::
          :ok | {:error, :not_found | :not_open}
  def remove_participant(id, user_id, participant_id) do
    with {:ok, participant_id} <- cast_participant_id(participant_id),
         {:ok, _poll} <-
           OpenPollLock.with_locked(id, user_id, &delete_participant(&1, participant_id)) do
      :ok
    end
  end

  @doc """
  Sends a participant of the user's open poll their personal link again, for
  someone who lost the email. See `Tymeslot.Polls.Invitations.resend/2` for
  which email goes out and when it is refused.

  Written under the poll's row lock, like removing someone, so it never goes
  out for a poll confirmed in the meantime, and two clicks send one email.
  An id that is not a confirmed participant of this poll, including one that
  is not a UUID at all, is `{:error, :not_found}`.
  """
  @spec resend_invitation(Ecto.UUID.t(), integer(), String.t()) ::
          :ok
          | {:error,
             :not_found | :not_open | :no_username | :no_calendar | Invitations.resend_error()}
  def resend_invitation(id, user_id, participant_id) do
    with {:ok, participant_id} <- cast_participant_id(participant_id),
         :ok <- HostReadiness.ensure_calendar(user_id),
         {:ok, _poll} <-
           OpenPollLock.with_locked(id, user_id, fn poll ->
             with :ok <- HostReadiness.ensure_username(user_id, [participant_id]),
                  do: Invitations.resend(poll, participant_id)
           end) do
      :ok
    end
  end

  @doc """
  Whether the participant was invited by the host and has not voted yet, so
  sending their link again sends the invitation rather than the voting-link
  email.
  """
  @spec unanswered_invitee?(PollParticipantSchema.t()) :: boolean()
  defdelegate unanswered_invitee?(participant), to: PollParticipantSchema

  @doc """
  Deletes the user's poll once it is over, confirmed or cancelled, with its
  times, participants and votes, to tidy the list. The meeting a confirmed
  poll minted stays. An open poll has to be cancelled first, so nothing
  people are still voting on disappears.

  Jobs still pending for the poll are left to run. The cancellation email
  carries what it needs and still reaches every participant. Anything else
  was already deleted when the poll was confirmed or cancelled, or finds
  the poll gone and is discarded.
  """
  @spec delete_poll(Ecto.UUID.t(), integer()) :: :ok | {:error, :not_found | :still_open}
  def delete_poll(id, user_id) do
    case get_poll_for_host(id, user_id) do
      {:ok, %{status: :open}} ->
        {:error, :still_open}

      {:ok, poll} ->
        {:ok, _deleted} = PollQueries.delete(poll)
        broadcast_update(poll.id)
        :ok

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Invites `entries` (from `Tymeslot.Polls.Invitations.parse/1`) to the user's
  open poll and emails each new invitee their link once the invitations have
  committed. See `Tymeslot.Polls.Invitations.insert/2`.

  Written under the poll's row lock, like cancelling and editing, so an
  invitation never lands on a poll confirmed in the meantime, and the
  reminders it schedules are for the deadline the poll holds now.

  Returns `{:error, :voting_closed}` for an open poll whose deadline has
  passed (the host can move the deadline to invite more people) and
  `{:error, :not_open}` for one that is confirmed or cancelled, and
  `{:error, :no_calendar}` while the host has no calendar connected, since the
  voting page the invitations link to is closed until then.
  """
  @spec invite_participants(Ecto.UUID.t(), integer(), [Invitations.entry()]) ::
          {:ok, Invitations.result()}
          | {:error,
             :not_found
             | :not_open
             | :voting_closed
             | :poll_full
             | :no_username
             | :no_calendar
             | {:rate_limited, non_neg_integer()}
             | Ecto.Changeset.t()}
  def invite_participants(id, user_id, entries) do
    with :ok <- HostReadiness.ensure_calendar(user_id),
         {:ok, result} <-
           OpenPollLock.with_locked(id, user_id, fn poll ->
             with :ok <- ensure_voting_open(poll),
                  :ok <- HostReadiness.ensure_username(user_id, entries),
                  do: {:ok, Invitations.insert(poll, entries)}
           end) do
      :ok = Invitations.send_invitations(result.invited)
      {:ok, result}
    end
  end

  @doc """
  Cancels an open poll, notifies subscribers and emails every participant
  that it will not go ahead. Only open polls may be cancelled.
  """
  @spec cancel_poll(Ecto.UUID.t(), integer()) ::
          {:ok, PollSchema.t()} | {:error, :not_found | :not_open | Ecto.Changeset.t()}
  def cancel_poll(id, user_id) do
    OpenPollLock.with_locked(id, user_id, fn poll ->
      with {:ok, cancelled} <- PollQueries.update(PollSchema.cancel_changeset(poll)) do
        :ok = EmailScheduler.cancel_poll_deadline_jobs(cancelled.id)
        :ok = EmailScheduler.schedule_poll_cancellation(cancelled)
        {:ok, cancelled}
      end
    end)
  end

  @doc """
  Tallies votes per slot for a preloaded poll.

  Pure over `poll.time_slots` and `poll.participants[].votes` (both preloaded by
  the poll queries). Every slot appears in the result, including slots with no
  votes.
  """
  @spec tallies(PollSchema.t()) :: %{
          Ecto.UUID.t() => %{
            yes: non_neg_integer(),
            if_need_be: non_neg_integer(),
            no: non_neg_integer()
          }
        }
  def tallies(%{time_slots: time_slots, participants: participants}) do
    Map.new(time_slots, fn slot -> {slot.id, tally_slot(participants, slot.id)} end)
  end

  @doc """
  Counts the people on a poll who asked for a voting link and have not yet
  confirmed it by saving responses. They are not among `poll.participants`.
  """
  @spec count_unconfirmed(PollSchema.t()) :: non_neg_integer()
  def count_unconfirmed(%PollSchema{id: poll_id}),
    do: PollParticipantQueries.count_unconfirmed(poll_id)

  @doc """
  Whether the host has invited anyone to `poll` by address. Deadline
  reminders go only to invitees, so only such a poll has any to send.

  Pure over `poll.participants`, which must be preloaded (the poll queries
  do, and invitees are confirmed from the start, so none is left out).
  """
  @spec has_invitees?(PollSchema.t()) :: boolean()
  def has_invitees?(%PollSchema{participants: participants}),
    do: Enum.any?(participants, &match?(%{invited_at: %DateTime{}}, &1))

  @doc """
  Deletes the participants who never confirmed their voting link within its
  lifetime. Run daily by `Tymeslot.Workers.DataRetentionWorker`.
  """
  @spec prune_unconfirmed_participants() :: {non_neg_integer(), nil}
  def prune_unconfirmed_participants do
    PollParticipantQueries.delete_expired_unconfirmed(PollParticipantQueries.expiry_cutoff())
  end

  @doc """
  The slots leading on the votes in `tallies` (from `tallies/1`): those tied
  on the most yes votes, ties broken on "if need be", so a time half the group
  can only just make does not outrank one they can.

  Empty when nobody has said yes or if need be anywhere, and when every slot
  scores the same, since then no time leads.
  """
  @spec leading_slot_ids([map()], map()) :: [Ecto.UUID.t()]
  def leading_slot_ids(time_slots, tallies) do
    scores =
      Map.new(time_slots, fn slot ->
        counts = Map.get(tallies, slot.id, %{})
        {slot.id, {Map.get(counts, :yes, 0), Map.get(counts, :if_need_be, 0)}}
      end)

    leaders =
      case scores |> Map.values() |> Enum.max(fn -> {0, 0} end) do
        {0, 0} -> []
        best -> for {id, score} <- scores, score == best, do: id
      end

    if length(leaders) == map_size(scores), do: [], else: leaders
  end

  @doc """
  The slot of a confirmed poll that its meeting was booked at: the one
  starting when the meeting does. Nil for a poll that is not confirmed, and
  when its meeting is gone or starts at none of the poll's times.
  """
  @spec winning_slot_id(PollSchema.t()) :: Ecto.UUID.t() | nil
  def winning_slot_id(%{status: :confirmed, confirmed_meeting_id: meeting_id} = poll)
      when is_binary(meeting_id) do
    case Meetings.get_meeting(meeting_id) do
      {:ok, meeting} ->
        Enum.find_value(poll.time_slots, fn slot ->
          DateTime.compare(slot.start_time, meeting.start_time) == :eq && slot.id
        end)

      {:error, _reason} ->
        nil
    end
  end

  def winning_slot_id(_poll), do: nil

  @doc """
  Whether voting is open at `now` (by default the current time): open status
  and no deadline, or a deadline still in the future.
  """
  @spec voting_open?(PollSchema.t(), DateTime.t()) :: boolean()
  defdelegate voting_open?(poll, now \\ Clock.utc_now()), to: PollSchema

  @doc "Of `polls`, the one whose voting closes next after `now`, or nil."
  @spec next_to_close([PollSchema.t()], DateTime.t()) :: PollSchema.t() | nil
  defdelegate next_to_close(polls, now), to: PollSchema

  @doc "Subscribes the calling process to updates for a poll."
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(poll_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(poll_id))

  @doc "Unsubscribes the calling process from updates for a poll."
  @spec unsubscribe(Ecto.UUID.t()) :: :ok
  def unsubscribe(poll_id), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(poll_id))

  @doc "Broadcasts that a poll changed to its subscribers."
  @spec broadcast_update(Ecto.UUID.t()) :: :ok | {:error, term()}
  def broadcast_update(poll_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(poll_id), {:poll_updated, poll_id})
  end

  # --- Lifecycle helpers ---

  defp ensure_voting_open(poll),
    do: if(voting_open?(poll), do: :ok, else: {:error, :voting_closed})

  defp cast_participant_id(participant_id) do
    case UUID.cast(participant_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp delete_participant(poll, participant_id) do
    case PollParticipantQueries.delete_from_poll(poll.id, participant_id) do
      {1, _rows} ->
        :ok = after_participant_removed(poll)
        {:ok, poll}

      {0, _rows} ->
        {:error, :not_found}
    end
  end

  # In the removal's transaction, so both checks already read the poll
  # without the participant. The all-voted nudge needs invitees, and only
  # invitees are reminded, so a poll keeps one or the other in play.
  defp after_participant_removed(poll) do
    if PollParticipantQueries.any_invited?(poll.id) do
      Voting.notify_host_if_all_voted(poll)
    else
      EmailScheduler.cancel_poll_reminders(poll.id)
    end
  end

  # --- Tallying helpers ---

  defp tally_slot(participants, slot_id) do
    responses =
      for participant <- participants,
          vote <- participant.votes,
          vote.poll_time_slot_id == slot_id,
          do: vote.response

    Map.new(@responses, fn response -> {response, Enum.count(responses, &(&1 == response))} end)
  end

  defp topic(poll_id), do: "polls:#{poll_id}"
end
