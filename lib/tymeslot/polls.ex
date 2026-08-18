defmodule Tymeslot.Polls do
  @moduledoc """
  Context for meeting polls: creating polls with candidate slots, reading them
  for the host or for voting, tallying votes, and lifecycle transitions.
  """

  alias Tymeslot.Emails.EmailScheduler.PollScheduler
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Polls.{PollQueries, PollSchema, PollTimeSlotQueries, PollTimeSlotSchema}
  alias Tymeslot.Repo

  @pubsub Tymeslot.PubSub
  @responses [:yes, :if_need_be, :no]

  @doc """
  Creates a poll and all of its candidate slots in a single transaction.

  `attrs` carries `:title`, `:duration_minutes`, `:timezone`, and `:slots` (a
  list of `%{start_time: dt, end_time: dt}`; `end_time` may be omitted and then
  defaults to `start_time` plus the poll duration). `:description`,
  `:deadline_at`, and `:meeting_type_id` are optional.

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
             | Ecto.Changeset.t()}
  def create_poll(user_id, attrs) do
    with {:ok, attrs} <- apply_meeting_type(user_id, attrs),
         {:ok, slots} <- prepare_slots(attrs) do
      insert_poll(user_id, attrs, slots)
    end
  end

  @doc "Fetches a poll by its public token, in any status, for the voting page."
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
  Updates an open poll's title and description, and notifies subscribers.

  Only these two fields, and only while the poll is open. The candidate times,
  duration, timezone, and deadline are the terms guests voted against, so they
  are not editable; a confirmed poll has already minted a meeting that carries
  its own title, and a cancelled one is history.

  Subscribers are notified because the title and description are both on the
  public voting page, so an open voting tab shows the correction immediately.
  """
  @spec update_details(Ecto.UUID.t(), integer(), map()) ::
          {:ok, PollSchema.t()} | {:error, :not_found | :not_open | Ecto.Changeset.t()}
  def update_details(id, user_id, attrs) do
    with_poll(id, user_id, fn
      %{status: :open} = poll -> do_update_details(poll, attrs)
      _poll -> {:error, :not_open}
    end)
  end

  @doc "Cancels an open poll and notifies subscribers. Only open polls may be cancelled."
  @spec cancel_poll(Ecto.UUID.t(), integer()) ::
          {:ok, PollSchema.t()} | {:error, :not_found | :not_open | Ecto.Changeset.t()}
  def cancel_poll(id, user_id) do
    with_poll(id, user_id, fn
      %{status: :open} = poll -> do_cancel(poll)
      _poll -> {:error, :not_open}
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
    poll_attrs = attrs |> Map.put(:user_id, user_id) |> Map.drop([:slots])

    transaction =
      Repo.transaction(fn ->
        with {:ok, poll} <-
               PollQueries.insert(PollSchema.creation_changeset(%PollSchema{}, poll_attrs)),
             :ok <- insert_slots(poll, slots) do
          poll
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case transaction do
      {:ok, poll} ->
        :ok = PollScheduler.schedule_deadline_jobs(poll)
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

  defp do_cancel(poll) do
    case PollQueries.update(PollSchema.cancel_changeset(poll)) do
      {:ok, cancelled} ->
        :ok = PollScheduler.cancel_deadline_jobs(cancelled.id)
        broadcast_update(cancelled.id)
        {:ok, cancelled}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp do_update_details(poll, attrs) do
    case PollQueries.update(PollSchema.details_changeset(poll, attrs)) do
      {:ok, updated} ->
        broadcast_update(updated.id)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
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
