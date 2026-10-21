defmodule Tymeslot.Polls do
  @moduledoc """
  Context for meeting polls: creating polls with candidate slots, reading them
  for the host or for voting, tallying votes, and lifecycle transitions.
  """

  @behaviour Tymeslot.Security.EncryptedStorage

  alias Ecto.UUID
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.MeetingTypes

  alias Tymeslot.Polls.{
    Editing,
    Invitations,
    PollParticipantQueries,
    PollParticipantSchema,
    PollQueries,
    PollSchema,
    PollTimeSlotQueries,
    PollTimeSlotSchema,
    Voting
  }

  alias Tymeslot.Repo
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
             | {:rate_limited, non_neg_integer()}
             | Ecto.Changeset.t()}
  def create_poll(user_id, attrs) do
    with {:ok, attrs} <- apply_meeting_type(user_id, attrs),
         {:ok, slots} <- prepare_slots(attrs) do
      insert_poll(user_id, attrs, slots)
    end
  end

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
  def get_poll_for_host(id, user_id), do: with_poll(id, user_id, &{:ok, &1})

  @doc "Lists the user's polls, newest first."
  @spec list_polls(integer()) :: [PollSchema.t()]
  def list_polls(user_id), do: PollQueries.list_for_user(user_id)

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
           with_open_poll_locked(id, user_id, &delete_participant(&1, participant_id)) do
      :ok
    end
  end

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
    with_poll(id, user_id, fn
      %{status: :open} ->
        {:error, :still_open}

      poll ->
        {:ok, _deleted} = PollQueries.delete(poll)
        broadcast_update(poll.id)
        :ok
    end)
  end

  @doc """
  Invites `entries` (from `Tymeslot.Polls.Invitations.parse/1`) to the user's
  open poll and emails each new invitee their link. See
  `Tymeslot.Polls.Invitations.invite/2`.
  """
  @spec invite_participants(Ecto.UUID.t(), integer(), [Invitations.entry()]) ::
          {:ok, Invitations.result()}
          | {:error,
             :not_found
             | :not_open
             | :poll_full
             | {:rate_limited, non_neg_integer()}
             | Ecto.Changeset.t()}
  def invite_participants(id, user_id, entries) do
    with_poll(id, user_id, fn poll ->
      case Invitations.invite(poll, entries) do
        {:ok, result} ->
          broadcast_update(poll.id)
          {:ok, result}

        error ->
          error
      end
    end)
  end

  @doc """
  Cancels an open poll, notifies subscribers and emails every participant
  that it will not go ahead. Only open polls may be cancelled.
  """
  @spec cancel_poll(Ecto.UUID.t(), integer()) ::
          {:ok, PollSchema.t()} | {:error, :not_found | :not_open | Ecto.Changeset.t()}
  def cancel_poll(id, user_id) do
    with_open_poll_locked(id, user_id, fn poll ->
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

  @doc "Whether voting is currently open: open status and no deadline, or a deadline still in the future."
  @spec voting_open?(PollSchema.t()) :: boolean()
  def voting_open?(%{status: status}) when status != :open, do: false
  def voting_open?(%{deadline_at: nil}), do: true

  def voting_open?(%{deadline_at: deadline_at}) do
    DateTime.compare(DateTime.utc_now(), deadline_at) == :lt
  end

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

  # --- Creation helpers ---

  defp put_default_access(attrs, invitees) do
    case Map.get(attrs, :invite_only) do
      nil -> Map.put(attrs, :invite_only, default_invite_only?(invitees))
      _chosen -> attrs
    end
  end

  defp apply_meeting_type(_user_id, %{meeting_type_id: nil} = attrs), do: {:ok, attrs}

  defp apply_meeting_type(user_id, %{meeting_type_id: meeting_type_id} = attrs) do
    case MeetingTypes.get_meeting_type(meeting_type_id, user_id) do
      nil -> {:error, :meeting_type_not_found}
      %{payment_required: true} -> {:error, :payment_required_type}
      meeting_type -> {:ok, snapshot_meeting_type(attrs, meeting_type)}
    end
  end

  defp apply_meeting_type(_user_id, attrs), do: {:ok, attrs}

  defp snapshot_meeting_type(attrs, meeting_type) do
    attrs
    |> Map.put_new(:title, meeting_type.name)
    |> Map.put_new(:duration_minutes, meeting_type.duration_minutes)
  end

  defp prepare_slots(attrs) do
    slots = Map.get(attrs, :slots, [])
    duration = Map.get(attrs, :duration_minutes)

    cond do
      slots == [] -> {:error, :no_slots}
      length(slots) > PollSchema.max_slots() -> {:error, :too_many_slots}
      true -> build_slots(slots, duration)
    end
  end

  defp build_slots(slots, duration) do
    now = DateTime.utc_now()

    result =
      slots
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {slot, index}, {:ok, acc} ->
        if DateTime.compare(slot.start_time, now) == :gt do
          {:cont, {:ok, [build_slot(slot, index, duration) | acc]}}
        else
          {:halt, {:error, :slot_in_past}}
        end
      end)

    case result do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      error -> error
    end
  end

  defp build_slot(slot, index, duration) do
    %{start_time: slot.start_time, end_time: end_time_for(slot, duration), position: index}
  end

  defp end_time_for(slot, duration) do
    case {Map.get(slot, :end_time), duration} do
      {nil, minutes} when is_integer(minutes) ->
        DateTime.add(slot.start_time, minutes * 60, :second)

      {nil, _minutes} ->
        nil

      {end_time, _minutes} ->
        end_time
    end
  end

  defp insert_poll(user_id, attrs, slots) do
    {invitees, attrs} = Map.pop(attrs, :invitees, [])

    poll_attrs =
      attrs
      |> put_default_access(invitees)
      |> Map.put(:user_id, user_id)
      |> Map.drop([:slots])

    transaction =
      Repo.transaction(fn ->
        with {:ok, poll} <-
               PollQueries.insert(PollSchema.creation_changeset(%PollSchema{}, poll_attrs)),
             :ok <- insert_slots(poll, slots) do
          {poll, Invitations.insert(poll, invitees)}
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case transaction do
      {:ok, {poll, invitations}} ->
        :ok = EmailScheduler.schedule_poll_deadline_nudge(poll)
        :ok = Invitations.send_invitations(invitations.invited)
        {:ok, PollQueries.get_for_user(poll.id, user_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_slots(poll, slots) do
    Enum.reduce_while(slots, :ok, fn slot_attrs, :ok ->
      changeset =
        PollTimeSlotSchema.changeset(
          %PollTimeSlotSchema{},
          Map.put(slot_attrs, :poll_id, poll.id)
        )

      case PollTimeSlotQueries.insert(changeset) do
        {:ok, _slot} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  # --- Lifecycle helpers ---

  # A lifecycle write on an open poll (cancel, a details edit) reads the poll
  # under the row lock confirmation takes (`Tymeslot.Polls.Confirm`), so a
  # poll confirmed after the caller loaded its page is seen as confirmed here
  # and refused, rather than written over. `fun` gets the locked open poll and
  # returns `{:ok, poll}` or `{:error, reason}`; subscribers are told once the
  # write has committed.
  defp with_open_poll_locked(id, user_id, fun) do
    result =
      Repo.transaction(fn ->
        with %PollSchema{status: :open} = poll <- PollQueries.lock_for_user(id, user_id),
             {:ok, updated} <- fun.(poll) do
          updated
        else
          nil -> Repo.rollback(:not_found)
          %PollSchema{} -> Repo.rollback(:not_open)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, updated} <- result do
      broadcast_update(updated.id)
      {:ok, updated}
    end
  end

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

  defp with_poll(id, user_id, fun) do
    case PollQueries.get_for_user(id, user_id) do
      nil -> {:error, :not_found}
      poll -> fun.(poll)
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
