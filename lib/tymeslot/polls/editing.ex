defmodule Tymeslot.Polls.Editing do
  @moduledoc """
  Changes a host makes to an open poll: its details, deadline and reminders,
  and new candidate times.

  Everything is written in one transaction that holds the poll's row, so a
  confirmation racing an edit sees either all of it or none. After the
  commit:

    * a changed deadline or reminders replace the pending reminder and
      deadline jobs (`EmailScheduler.reschedule_poll_deadline_jobs/1`). A deadline
      set again after it passed reopens voting.
    * new times are announced to everyone who has already voted, who would
      otherwise not know there is more to answer. Whoever has not voted yet
      sees them when they open their link.

  Existing times are never changed or removed here: they are what guests
  voted against. A meeting type set here only chooses the calendar and video
  provider the confirmed meeting uses; the poll keeps its own title and
  times, and the type's schedule plays no part in confirming one of them.
  """

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollQueries, PollSchema, PollTimeSlotQueries, PollTimeSlotSchema}
  alias Tymeslot.Repo

  @type reason ::
          :not_found
          | :not_open
          | :too_many_slots
          | :slot_in_past
          | :meeting_type_not_found
          | :payment_required_type
          | Changeset.t()

  @doc """
  Applies `attrs` (see `PollSchema.details_changeset/2`) to the user's open
  poll and adds a candidate time starting at each of `new_starts`, each as
  long as the poll's duration.
  """
  @spec update(Ecto.UUID.t(), integer(), map(), [DateTime.t()]) ::
          {:ok, PollSchema.t()} | {:error, reason()}
  def update(id, user_id, attrs, new_starts \\ []) do
    case Repo.transaction(fn -> write(id, user_id, attrs, new_starts) end) do
      {:ok, {poll, changeset, added}} ->
        after_commit(poll, changeset, added)
        {:ok, poll}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write(id, user_id, attrs, new_starts) do
    with {:ok, poll} <- lock(id, user_id),
         :ok <- check_meeting_type(attrs, user_id),
         changeset = PollSchema.details_changeset(poll, attrs),
         {:ok, updated} <- PollQueries.update(changeset),
         {:ok, added} <- add_slots(updated, new_starts) do
      {updated, changeset, added}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock(id, user_id) do
    case PollQueries.lock_for_user(id, user_id) do
      nil -> {:error, :not_found}
      %PollSchema{status: :open} = poll -> {:ok, poll}
      _closed -> {:error, :not_open}
    end
  end

  # The same rule creating a poll applies: the host's own type, and not a
  # paid one, since confirming a poll takes no payment.
  defp check_meeting_type(attrs, user_id) do
    case Map.get(attrs, "meeting_type_id", Map.get(attrs, :meeting_type_id)) do
      nil ->
        :ok

      id ->
        case MeetingTypes.get_meeting_type(id, user_id) do
          nil -> {:error, :meeting_type_not_found}
          %{payment_required: true} -> {:error, :payment_required_type}
          _meeting_type -> :ok
        end
    end
  end

  defp add_slots(_poll, []), do: {:ok, []}

  defp add_slots(poll, new_starts) do
    now = DateTime.utc_now()

    cond do
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

  defp after_commit(poll, changeset, added) do
    if Changeset.changed?(changeset, :deadline_at) or
         Changeset.changed?(changeset, :reminder_config) do
      EmailScheduler.reschedule_poll_deadline_jobs(poll)
    end

    if added != [], do: EmailScheduler.schedule_poll_new_times(poll, added)

    Polls.broadcast_update(poll.id)
  end
end
