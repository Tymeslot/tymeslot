defmodule Tymeslot.Availability.DateOverrides do
  @moduledoc """
  One date's exception to a schedule's weekly hours: closed that day
  (`unavailable`), open on other hours (`custom_hours`), or open on the
  usual hours (`available`). A schedule holds at most one per date, and it
  replaces that date's weekly window rather than adding to it.

  Every function takes the acting profile's id and reaches the schedule only
  through it, so another profile's schedule is `{:error, :not_found}` whatever
  id is passed. A write is refused for a date already gone on the owner's
  clock, and every change calls `Tymeslot.Availability.changed/1`, so booking
  pages and calendars compute afresh.

  A caller writing several things in one transaction passes `notify: false`
  to the writes and calls `changed/1` itself once the transaction commits:
  told before then, a reader would compute afresh from the old rows.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Availability.AvailabilityOverrideQueries
  alias Tymeslot.Availability.AvailabilityOverrideSchema
  alias Tymeslot.Availability.AvailabilityScheduleQueries
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.DateTimeUtils

  # What an override that is not given a field holds, so replacing custom
  # hours with a closed day leaves no stale hours behind.
  @blank %{start_time: nil, end_time: nil, ends_next_day: false, reason: nil}

  @doc "The schedule's override on `date`, or nil."
  @spec get(integer(), integer(), Date.t()) ::
          {:ok, AvailabilityOverrideSchema.t() | nil} | {:error, :not_found}
  def get(profile_id, schedule_id, %Date{} = date) do
    with {:ok, schedule} <- owned_schedule(profile_id, schedule_id) do
      {:ok, AvailabilityOverrideQueries.get_override_by_schedule_and_date(schedule.id, date)}
    end
  end

  @doc """
  As `get/3`, locking the override until the caller's transaction ends.
  Call it inside a transaction.
  """
  @spec lock(integer(), integer(), Date.t()) ::
          {:ok, AvailabilityOverrideSchema.t() | nil} | {:error, :not_found}
  def lock(profile_id, schedule_id, %Date{} = date) do
    with {:ok, schedule} <- owned_schedule(profile_id, schedule_id) do
      {:ok, AvailabilityOverrideQueries.lock_override_by_schedule_and_date(schedule.id, date)}
    end
  end

  @doc """
  Writes the schedule's override on `attrs.date`, replacing any it has.
  `attrs` takes `:date`, `:override_type`, and for custom hours
  `:start_time`, `:end_time` and `:ends_next_day`, plus an optional
  `:reason`; a field left out is cleared. Takes `notify: false` (see the
  moduledoc).
  """
  @spec upsert(integer(), integer(), map(), keyword()) ::
          {:ok, AvailabilityOverrideSchema.t()}
          | {:error, :not_found | :in_past | Ecto.Changeset.t()}
  def upsert(profile_id, schedule_id, %{date: %Date{} = date} = attrs, opts \\ []) do
    with {:ok, schedule} <- owned_schedule(profile_id, schedule_id),
         :ok <- not_in_past(profile_id, date),
         {:ok, override} <- write(schedule.id, date, attrs) do
      notify(schedule, opts)
      {:ok, override}
    end
  end

  @doc """
  As `upsert/3`, without the refusal of a past date. For putting back an
  override that was there before a change (an undo): after midnight the date
  may be gone on the owner's clock, but what it held is still the truth.
  """
  @spec put_back(integer(), integer(), map(), keyword()) ::
          {:ok, AvailabilityOverrideSchema.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def put_back(profile_id, schedule_id, %{date: %Date{} = date} = attrs, opts \\ []) do
    with {:ok, schedule} <- owned_schedule(profile_id, schedule_id),
         {:ok, override} <- write(schedule.id, date, attrs) do
      notify(schedule, opts)
      {:ok, override}
    end
  end

  @doc """
  Removes the schedule's override on `date`. Nothing to remove is not an
  error, so an undo that arrives twice is harmless. Allowed for a past date:
  it changes nothing a guest can book.
  """
  @spec delete(integer(), integer(), Date.t(), keyword()) :: :ok | {:error, :not_found}
  def delete(profile_id, schedule_id, %Date{} = date, opts \\ []) do
    with {:ok, schedule} <- owned_schedule(profile_id, schedule_id) do
      AvailabilityOverrideQueries.delete_by_schedule_and_date(schedule.id, date)
      notify(schedule, opts)
      :ok
    end
  end

  defp notify(schedule, opts) do
    if Keyword.get(opts, :notify, true), do: Availability.changed(schedule)
    :ok
  end

  # One upsert, so two writes for one date that both found nothing cannot
  # collide on the unique index (which would abort a caller's transaction).
  defp write(schedule_id, date, attrs) do
    @blank
    |> Map.merge(Map.take(attrs, [:override_type | Map.keys(@blank)]))
    |> Map.merge(%{schedule_id: schedule_id, date: date})
    |> AvailabilityOverrideQueries.upsert_override()
  end

  defp owned_schedule(profile_id, schedule_id)
       when is_integer(profile_id) and is_integer(schedule_id) do
    case AvailabilityScheduleQueries.get_for_profile(schedule_id, profile_id) do
      nil -> {:error, :not_found}
      schedule -> {:ok, schedule}
    end
  end

  defp owned_schedule(_profile_id, _schedule_id), do: {:error, :not_found}

  # Read on the owner's clock: late on the 17th in Berlin is already the 18th
  # in Tokyo, and the override's date is the owner's.
  defp not_in_past(profile_id, date) do
    today =
      profile_id
      |> Profiles.get_profile_by_id()
      |> Profiles.timezone()
      |> DateTimeUtils.now_in_timezone()
      |> DateTime.to_date()

    if Date.before?(date, today), do: {:error, :in_past}, else: :ok
  end
end
