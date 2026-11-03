defmodule Tymeslot.MeetingTypes.OfferedTimes do
  @moduledoc """
  The exact start times a one-to-one meeting type with fixed dates offers
  (`Tymeslot.MeetingTypes.FixedDates.offered_times?/1`).

  Where a group type's fixed dates are planned sessions, meetings created up
  front, an offered time is only a candidate start. It replaces the weekly
  schedule as the source of the type's starts
  (`Tymeslot.Availability.SlotGrid`), and every other rule still applies to
  it: the host's calendar and bookings, buffers, minimum notice, the booking
  window, booking limits and time off. Booking one makes an ordinary
  one-to-one meeting, which then hides the time as any booking hides the
  times it overlaps; cancelling that meeting offers the time again.

  The host enters each time in their own time zone; it is stored as an
  instant. Every function that changes a type's times takes the acting
  user's id and refuses with `{:error, :not_found}` a type that user does
  not own. Past times are deleted by the daily retention run
  (`prune_past/1`).
  """

  alias Ecto.Changeset
  alias Tymeslot.Availability
  alias Tymeslot.Clock
  alias Tymeslot.MeetingTypes.{FixedDates, OfferedTimeQueries, OfferedTimeSchema}

  # Plenty for a few times a week for months ahead, and a bound on what
  # every availability calculation of the type has to read, as
  # `Tymeslot.Availability.ExtraAvailability` bounds extra times.
  @max_per_type 100

  @type add_error :: :not_found | :not_fixed_dates | :start_in_past | :duplicate | :too_many

  @spec max_per_type() :: pos_integer()
  def max_per_type, do: @max_per_type

  @doc "The type's offered times, past ones not yet pruned included, in start order."
  @spec list(map()) :: [OfferedTimeSchema.t()]
  def list(%{id: meeting_type_id}) when is_integer(meeting_type_id),
    do: OfferedTimeQueries.list_for_type(meeting_type_id)

  def list(_meeting_type), do: []

  @doc "The type's offered times that start after `now`, in start order."
  @spec upcoming(map(), DateTime.t()) :: [OfferedTimeSchema.t()]
  def upcoming(meeting_type, now \\ Clock.utc_now())

  def upcoming(%{id: meeting_type_id}, now) when is_integer(meeting_type_id) do
    OfferedTimeQueries.list_for_type(meeting_type_id, now)
  end

  def upcoming(_meeting_type, _now), do: []

  @doc """
  The candidate starts the slot engine offers for `meeting_type`: its
  upcoming offered times as instants when it is a one-to-one type with
  fixed dates, `nil` for any other type, which offers its schedule's.
  """
  @spec starts_for(map() | nil, DateTime.t()) :: [DateTime.t()] | nil
  def starts_for(meeting_type, now \\ Clock.utc_now()) do
    if FixedDates.offered_times?(meeting_type),
      do: meeting_type |> upcoming(now) |> Enum.map(& &1.starts_at)
  end

  @doc """
  For each of `meeting_types`, its next offered time, or nil, keyed by type
  id, in one query.
  """
  @spec next_by_type([map()], DateTime.t()) :: %{integer() => DateTime.t() | nil}
  def next_by_type(meeting_types, now \\ Clock.utc_now()) do
    ids = Enum.map(meeting_types, & &1.id)

    next =
      ids
      |> OfferedTimeQueries.list_for_types(now)
      |> Enum.group_by(& &1.meeting_type_id)
      |> Map.new(fn {id, [first | _later]} -> {id, first.starts_at} end)

    Map.new(ids, &{&1, Map.get(next, &1)})
  end

  @doc """
  Offers `starts_at` (any zone; stored to the second, in UTC) on
  `meeting_type`, which `user_id` must own and which must be a one-to-one
  type with fixed dates.

  Refuses a time not after `now` (`:start_in_past`), one already offered
  (`:duplicate`) and more than `max_per_type/0` (`:too_many`).
  """
  @spec add(map(), integer(), DateTime.t(), DateTime.t()) ::
          {:ok, OfferedTimeSchema.t()} | {:error, add_error()}
  def add(meeting_type, user_id, starts_at, now \\ Clock.utc_now())

  def add(%{id: type_id, user_id: user_id} = meeting_type, user_id, %DateTime{} = starts_at, now) do
    starts_at = starts_at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

    changeset =
      OfferedTimeSchema.changeset(%OfferedTimeSchema{}, %{
        meeting_type_id: type_id,
        starts_at: starts_at
      })

    with :ok <- check_offered_times(meeting_type),
         :ok <- check_start(starts_at, now),
         :ok <- check_room(type_id),
         {:ok, offered_time} <- insert(changeset) do
      Availability.changed(user_id)
      {:ok, offered_time}
    end
  end

  def add(_meeting_type, _user_id, _starts_at, _now), do: {:error, :not_found}

  @doc "Removes the offered time `id` of `meeting_type`, which `user_id` must own."
  @spec delete(map(), integer(), integer() | String.t()) ::
          {:ok, OfferedTimeSchema.t()} | {:error, :not_found}
  def delete(%{id: type_id, user_id: user_id}, user_id, id) do
    with id when is_integer(id) <- to_integer(id),
         %OfferedTimeSchema{} = offered_time <- OfferedTimeQueries.get_for_type(type_id, id),
         {:ok, deleted} <- OfferedTimeQueries.delete(offered_time) do
      Availability.changed(user_id)
      {:ok, deleted}
    else
      _missing -> {:error, :not_found}
    end
  end

  def delete(_meeting_type, _user_id, _id), do: {:error, :not_found}

  @doc """
  Deletes every type's offered times starting before `cutoff`. Run daily by
  `Tymeslot.Workers.DataRetentionWorker`; a time that has started can no
  longer be booked, so nothing that matters is lost.
  """
  @spec prune_past(DateTime.t()) :: {non_neg_integer(), nil}
  def prune_past(%DateTime{} = cutoff), do: OfferedTimeQueries.delete_before(cutoff)

  defp check_offered_times(meeting_type) do
    if FixedDates.offered_times?(meeting_type), do: :ok, else: {:error, :not_fixed_dates}
  end

  defp check_start(starts_at, now) do
    if DateTime.compare(starts_at, now) == :gt, do: :ok, else: {:error, :start_in_past}
  end

  defp check_room(type_id) do
    if OfferedTimeQueries.count_for_type(type_id) < @max_per_type,
      do: :ok,
      else: {:error, :too_many}
  end

  # The unique index on (type, start) is the one constraint a valid
  # changeset can still hit, short of the type having just been deleted.
  defp insert(changeset) do
    case OfferedTimeQueries.insert(changeset) do
      {:ok, offered_time} ->
        {:ok, offered_time}

      {:error, %Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :starts_at),
          do: {:error, :duplicate},
          else: {:error, :not_found}
    end
  end

  defp to_integer(id) when is_integer(id), do: id

  defp to_integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _invalid -> nil
    end
  end

  defp to_integer(_id), do: nil
end
