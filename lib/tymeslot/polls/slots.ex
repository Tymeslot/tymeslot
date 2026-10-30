defmodule Tymeslot.Polls.Slots do
  @moduledoc """
  The rules a poll's candidate times are held to wherever they are added,
  when the poll is created and when the host adds times to it later: at most
  `PollSchema.max_slots/0` of them, each starting in the future.
  """

  alias Tymeslot.Polls.{PollSchema, PollTimeSlotQueries, PollTimeSlotSchema}

  @doc "`:ok` when a poll may hold `count` candidate times."
  @spec check_count(non_neg_integer()) :: :ok | {:error, :too_many_slots}
  def check_count(count) do
    if count > PollSchema.max_slots(), do: {:error, :too_many_slots}, else: :ok
  end

  @doc "`:ok` when every one of `start_times` is after now."
  @spec check_future(Enumerable.t()) :: :ok | {:error, :slot_in_past}
  def check_future(start_times) do
    now = DateTime.utc_now()

    if Enum.all?(start_times, &(DateTime.compare(&1, now) == :gt)),
      do: :ok,
      else: {:error, :slot_in_past}
  end

  @doc """
  Inserts a time slot on `poll` for each of `slots` (attrs carrying
  `:start_time`, `:end_time` and `:position`), in order, stopping at the
  first that fails. Callers run it in the poll's transaction, which the
  failure rolls back.
  """
  @spec insert(PollSchema.t(), [map()]) ::
          {:ok, [PollTimeSlotSchema.t()]} | {:error, Ecto.Changeset.t()}
  def insert(poll, slots) do
    slots
    |> Enum.reduce_while({:ok, []}, fn slot_attrs, {:ok, inserted} ->
      changeset =
        PollTimeSlotSchema.changeset(
          %PollTimeSlotSchema{},
          Map.put(slot_attrs, :poll_id, poll.id)
        )

      case PollTimeSlotQueries.insert(changeset) do
        {:ok, slot} -> {:cont, {:ok, [slot | inserted]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> reverse_inserted()
  end

  defp reverse_inserted({:ok, inserted}), do: {:ok, Enum.reverse(inserted)}
  defp reverse_inserted(error), do: error
end
