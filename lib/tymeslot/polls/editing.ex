defmodule Tymeslot.Polls.Editing do
  @moduledoc """
  Changes a host makes to an open poll: its details, who can vote, deadline
  and reminders, and new candidate times.

  Making a poll invite-only withdraws the link requests nobody has voted
  with yet; everyone confirmed stays.

  Everything is written in one transaction that holds the poll's row, so a
  confirmation racing an edit sees either all of it or none. The emails the
  edit sets off are scheduled in that transaction too, since Oban writes its
  jobs through the same repo. A confirmation waiting on the row then finds
  those jobs and deletes them with the rest, and an edit that rolls back
  schedules nothing:

    * a changed deadline or reminders replace the pending reminder and
      deadline jobs (`EmailScheduler.reschedule_poll_deadline_jobs/2`),
      reminders only while the poll has invitees. A deadline set again
      after it passed reopens voting.
    * new times are announced to everyone who has already voted, who would
      otherwise not know there is more to answer. Whoever has not voted yet
      sees them when they open their link. Times are added only while
      voting is open once the edit is applied: on a poll whose deadline has
      passed, the announcement would ask people to answer what they no
      longer can, so the same edit has to move the deadline first.

  Subscribers are told once the edit has committed.

  Existing times are never changed or removed here: they are what guests
  voted against. A meeting type set here only chooses the calendar and video
  provider the confirmed meeting uses; the poll keeps its own title and
  times, and the type's schedule plays no part in confirming one of them.
  """

  alias Ecto.{Changeset, Type}
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Polls

  alias Tymeslot.Polls.{
    PollParticipantQueries,
    PollQueries,
    PollSchema,
    PollTimeSlotQueries,
    PollTimeSlotSchema
  }

  alias Tymeslot.Repo

  @type reason ::
          :not_found
          | :not_open
          | :too_many_slots
          | :slot_in_past
          | :voting_closed
          | :meeting_type_not_found
          | :payment_required_type
          | Changeset.t()

  @doc """
  Applies `attrs` (see `PollSchema.details_changeset/2`) to the user's open
  poll and adds a candidate time starting at each of `new_starts`, each as
  long as the poll's duration.

  New times on a poll whose voting has closed, and that `attrs` does not
  reopen, are refused with `{:error, :voting_closed}`, and nothing is saved.
  """
  @spec update(Ecto.UUID.t(), integer(), map(), [DateTime.t()]) ::
          {:ok, PollSchema.t()} | {:error, reason()}
  def update(id, user_id, attrs, new_starts \\ []) do
    case Repo.transaction(fn -> write(id, user_id, attrs, new_starts) end) do
      {:ok, poll} ->
        Polls.broadcast_update(poll.id)
        {:ok, poll}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write(id, user_id, attrs, new_starts) do
    with {:ok, poll} <- lock(id, user_id),
         :ok <- check_meeting_type(poll, attrs, user_id),
         changeset = PollSchema.details_changeset(poll, attrs),
         {:ok, updated} <- PollQueries.update(changeset),
         :ok <- withdraw_requests(updated, changeset),
         {:ok, added} <- add_slots(updated, new_starts) do
      :ok = schedule_emails(updated, changeset, added)
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Switching to invite-only withdraws the requests waiting on the poll: the
  # people who asked for a link but never voted with it came in by the door
  # the host has just shut. Everyone confirmed stays, whether invited or not.
  # Inside the poll's row lock, so the switch and the withdrawal land
  # together. Switching back deletes nothing and just takes requests again.
  defp withdraw_requests(poll, changeset) do
    if Changeset.get_change(changeset, :invite_only) == true do
      {_count, _rows} = PollParticipantQueries.delete_unconfirmed_for_poll(poll.id)
    end

    :ok
  end

  defp lock(id, user_id) do
    case PollQueries.lock_for_user(id, user_id) do
      nil -> {:error, :not_found}
      %PollSchema{status: :open} = poll -> {:ok, poll}
      _closed -> {:error, :not_open}
    end
  end

  # A type the edit sets is held to the rule creating a poll applies
  # (`Polls.meeting_types_for_poll/1`): the host's own, not a paid one, since
  # confirming a poll takes no payment, and not a one-off event. The type the
  # poll already has passes as it is, even once it has been switched off or
  # has started taking payment, so an edit that leaves it alone never fails
  # on it.
  defp check_meeting_type(%PollSchema{meeting_type_id: current}, attrs, user_id) do
    case Map.get(attrs, "meeting_type_id", Map.get(attrs, :meeting_type_id)) do
      blank when blank in [nil, ""] -> :ok
      raw -> check_new_meeting_type(Type.cast(:id, raw), current, user_id)
    end
  end

  defp check_new_meeting_type({:ok, current}, current, _user_id), do: :ok
  defp check_new_meeting_type(:error, _current, _user_id), do: {:error, :meeting_type_not_found}

  defp check_new_meeting_type({:ok, id}, _current, user_id) do
    case MeetingTypes.get_meeting_type(id, user_id) do
      nil -> {:error, :meeting_type_not_found}
      %{payment_required: true} -> {:error, :payment_required_type}
      %{one_off: true} -> {:error, :meeting_type_not_found}
      _meeting_type -> :ok
    end
  end

  defp add_slots(_poll, []), do: {:ok, []}

  defp add_slots(poll, new_starts) do
    now = DateTime.utc_now()

    cond do
      not PollSchema.voting_open?(poll) ->
        {:error, :voting_closed}

      length(poll.time_slots) + length(new_starts) > PollSchema.max_slots() ->
        {:error, :too_many_slots}

      Enum.any?(new_starts, &(DateTime.compare(&1, now) != :gt)) ->
        {:error, :slot_in_past}

      true ->
        insert_slots(poll, new_starts)
    end
  end

  defp insert_slots(poll, new_starts) do
    first_position = Enum.reduce(poll.time_slots, -1, &max(&1.position, &2)) + 1

    new_starts
    |> Enum.sort(DateTime)
    |> Enum.with_index(first_position)
    |> Enum.reduce_while({:ok, []}, fn {start_time, position}, {:ok, added} ->
      attrs = %{
        poll_id: poll.id,
        start_time: start_time,
        end_time: DateTime.add(start_time, poll.duration_minutes * 60, :second),
        position: position
      }

      case PollTimeSlotQueries.insert(PollTimeSlotSchema.changeset(%PollTimeSlotSchema{}, attrs)) do
        {:ok, slot} -> {:cont, {:ok, [slot | added]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> reverse_added()
  end

  defp reverse_added({:ok, added}), do: {:ok, Enum.reverse(added)}
  defp reverse_added(error), do: error

  defp schedule_emails(poll, changeset, added) do
    if Changeset.changed?(changeset, :deadline_at) or
         Changeset.changed?(changeset, :reminder_config) do
      :ok =
        EmailScheduler.reschedule_poll_deadline_jobs(
          poll,
          PollParticipantQueries.any_invited?(poll.id)
        )
    end

    if added != [], do: :ok = EmailScheduler.schedule_poll_new_times(poll, added)
    :ok
  end
end
