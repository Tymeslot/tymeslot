defmodule Tymeslot.Availability.Schedules do
  @moduledoc """
  Named availability schedules: the single entry point for creating, editing and
  resolving the schedule a meeting type is booked against.

  Every profile has exactly one default schedule. A meeting type with no
  `availability_schedule_id` resolves to that default, so a meeting type is
  never left without a schedule, including after the schedule it pointed at is
  deleted, which nilifies the reference at the database level.
  """

  alias Tymeslot.Availability.AvailabilityBreakQueries
  alias Tymeslot.Availability.AvailabilityOverrideQueries
  alias Tymeslot.Availability.AvailabilityScheduleQueries
  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Availability.WeeklyAvailabilityQueries
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo
  alias Tymeslot.Validation.Constraints

  @default_schedule_name "Working hours"

  # A profile's schedules are presented as a tab strip, which stops reading as
  # navigation once there are too many of them. The cap keeps that surface
  # legible; it is deliberately low and easy to raise.
  @max_schedules 5

  @policy_fields [:buffer_minutes, :min_advance_hours, :advance_booking_days]

  @type schedule :: AvailabilityScheduleSchema.t()
  @type result :: {:ok, schedule()} | {:error, Ecto.Changeset.t() | atom()}

  @doc """
  Lists a profile's schedules, default first.
  """
  @spec list_for_profile(integer()) :: [schedule()]
  defdelegate list_for_profile(profile_id), to: AvailabilityScheduleQueries, as: :list_by_profile

  @doc """
  Fetches a profile's default schedule, or `nil` when the profile has none.
  """
  @spec get_default(integer() | nil) :: schedule() | nil
  defdelegate get_default(profile_id), to: AvailabilityScheduleQueries

  @doc """
  Fetches one of a profile's schedules by id, scoped so a caller cannot read
  another account's schedule by guessing an id.
  """
  @spec get_for_profile(integer(), integer()) :: schedule() | nil
  defdelegate get_for_profile(id, profile_id), to: AvailabilityScheduleQueries

  @doc """
  Creates the profile's default schedule and seeds its seven weekday rows.

  Accepts an optional repo so profile creation can run it inside the surrounding
  transaction.
  """
  @spec create_default(integer(), Ecto.Repo.t()) :: result()
  def create_default(profile_id, repo \\ Repo) do
    attrs = %{profile_id: profile_id, name: @default_schedule_name, is_default: true}

    with {:ok, schedule} <- AvailabilityScheduleQueries.insert(attrs, repo),
         {:ok, _count} <- WeeklyAvailabilityQueries.create_default_weekly_days(schedule.id, repo) do
      {:ok, schedule}
    end
  end

  @doc """
  The maximum number of schedules one profile may own.
  """
  @spec max_schedules() :: pos_integer()
  def max_schedules, do: @max_schedules

  @doc """
  Whether a profile has room for another schedule.

  Callers use this to hide the actions that would fail, rather than offering a
  button whose only outcome is an error.
  """
  @spec can_create?(integer()) :: boolean()
  def can_create?(profile_id) do
    AvailabilityScheduleQueries.count_by_profile(profile_id) < @max_schedules
  end

  @doc """
  Creates an additional (non-default) schedule and seeds its seven weekday rows,
  so a new schedule is immediately editable rather than half-populated.

  Returns `{:error, :schedule_limit_reached}` once the profile owns
  `max_schedules/0` of them.
  """
  @spec create(integer(), map()) :: result()
  def create(profile_id, attrs) do
    attrs =
      attrs
      |> normalise_attrs()
      |> Map.merge(%{profile_id: profile_id, is_default: false})

    Repo.transaction(fn ->
      # Counted inside the transaction so two concurrent creates cannot both
      # read a count below the cap and each insert past it.
      with :ok <- check_limit(profile_id),
           {:ok, schedule} <- AvailabilityScheduleQueries.insert(attrs),
           {:ok, _count} <- WeeklyAvailabilityQueries.create_default_weekly_days(schedule.id) do
        schedule
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Renames a schedule.
  """
  @spec rename(schedule(), String.t()) :: result()
  def rename(%AvailabilityScheduleSchema{} = schedule, name) do
    AvailabilityScheduleQueries.update(schedule, %{name: name})
  end

  @doc """
  Updates the schedule's buffer, minimum notice and advance booking window.
  """
  @spec update_policy(schedule(), map()) :: result()
  def update_policy(%AvailabilityScheduleSchema{} = schedule, attrs) do
    schedule
    |> AvailabilityScheduleQueries.update_policy(normalise_attrs(attrs))
    |> invalidate_cache(schedule)
  end

  @doc """
  Makes `schedule` the profile's default, clearing the flag from the previous one
  in the same transaction so the partial unique index is never violated.
  """
  @spec set_default(schedule()) :: result()
  def set_default(%AvailabilityScheduleSchema{is_default: true} = schedule), do: {:ok, schedule}

  def set_default(%AvailabilityScheduleSchema{} = schedule) do
    promoted =
      Repo.transaction(fn ->
        # Clearing before marking matters: the partial unique index allows only
        # one default per profile, so the two writes cannot be reordered.
        AvailabilityScheduleQueries.clear_default(schedule.profile_id)
        AvailabilityScheduleQueries.mark_default(schedule.id)

        %{schedule | is_default: true}
      end)

    invalidate_cache(promoted, schedule)
  end

  @doc """
  Copies a schedule's weekly pattern, breaks and policy under a new name.

  Date overrides are deliberately not copied: they name specific calendar dates,
  and carrying a stale exception list into a copy is more often wrong than right.

  Returns `{:error, :schedule_limit_reached}` once the profile owns
  `max_schedules/0` of them.
  """
  @spec duplicate(schedule(), String.t()) :: result()
  def duplicate(%AvailabilityScheduleSchema{} = source, name) do
    attrs =
      source
      |> Map.take(@policy_fields)
      |> Map.merge(%{profile_id: source.profile_id, name: name, is_default: false})

    copy =
      Repo.transaction(fn ->
        with :ok <- check_limit(source.profile_id),
             {:ok, inserted} <- AvailabilityScheduleQueries.insert(attrs) do
          copy_weekly_days(source.id, inserted.id)
          inserted
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    invalidate_cache(copy, source)
  end

  @doc """
  Deletes a schedule.

  The default schedule cannot be deleted; meeting types pointing at any other
  schedule revert to the default when it goes.
  """
  @spec delete(schedule()) :: result()
  def delete(%AvailabilityScheduleSchema{is_default: true}), do: {:error, :cannot_delete_default}

  def delete(%AvailabilityScheduleSchema{} = schedule) do
    schedule
    |> AvailabilityScheduleQueries.delete()
    |> invalidate_cache(schedule)
  end

  @doc """
  Names of the meeting types currently using a schedule, so a delete
  confirmation can say which ones fall back to the default.
  """
  @spec meeting_type_names(integer()) :: [String.t()]
  defdelegate meeting_type_names(schedule_id), to: AvailabilityScheduleQueries

  @doc """
  Whether a schedule has any date overrides.

  `duplicate/2` leaves them behind on purpose, so a caller can use this to say
  so at the moment it matters rather than letting the copy quietly differ.
  """
  @spec has_overrides?(integer()) :: boolean()
  def has_overrides?(schedule_id) do
    AvailabilityOverrideQueries.count_by_schedule(schedule_id) > 0
  end

  @doc """
  Resolves the schedule a meeting type is booked against: its own when set, the
  owning profile's default otherwise.

  Returns `nil` only when no meeting type is given, or when the owner has no
  profile; the engine treats a nil schedule as "use fallback hours".
  """
  @spec resolve_for_meeting_type(map() | nil) :: schedule() | nil
  def resolve_for_meeting_type(nil), do: nil

  def resolve_for_meeting_type(%{availability_schedule_id: id}) when is_integer(id) do
    AvailabilityScheduleQueries.get(id)
  end

  def resolve_for_meeting_type(%{user_id: user_id}) when is_integer(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, profile} -> get_default(profile.id)
      {:error, :not_found} -> nil
    end
  end

  def resolve_for_meeting_type(_meeting_type), do: nil

  @doc """
  Resolves the schedule for a meeting type, falling back to the given profile's
  default without a second profile lookup.

  This is the variant used by the booking page, where the organiser's profile is
  already loaded.
  """
  @spec resolve_for(map() | nil, map() | nil) :: schedule() | nil
  def resolve_for(%{availability_schedule_id: id}, _profile) when is_integer(id) do
    AvailabilityScheduleQueries.get(id)
  end

  def resolve_for(_meeting_type, %{id: profile_id}) when is_integer(profile_id) do
    get_default(profile_id)
  end

  def resolve_for(_meeting_type, _profile), do: nil

  @doc """
  The name given to a profile's default schedule at creation time.
  """
  @spec default_schedule_name() :: String.t()
  def default_schedule_name, do: @default_schedule_name

  @doc """
  One scheduling policy value for a resolved schedule.

  A nil schedule means none could be resolved (a profile mid-creation, or demo
  data) and falls back to `Tymeslot.Validation.Constraints`, which is the same
  table the engine and the schema's column defaults use. Every caller that can
  hold a nil schedule reads through here, so the offered slots and the
  booking-time re-check cannot disagree about what applies when there is none.
  """
  @spec policy(schedule() | nil, atom()) :: integer()
  def policy(nil, key), do: Map.fetch!(Constraints.scheduling_policy_defaults(), key)
  def policy(schedule, key), do: Map.fetch!(schedule, key)

  defp check_limit(profile_id) do
    if can_create?(profile_id), do: :ok, else: {:error, :schedule_limit_reached}
  end

  defp copy_weekly_days(source_schedule_id, target_schedule_id) do
    source_schedule_id
    |> WeeklyAvailabilityQueries.get_weekly_schedule_with_breaks()
    |> Enum.each(fn day ->
      {:ok, copy} =
        WeeklyAvailabilityQueries.create_weekly_availability(%{
          schedule_id: target_schedule_id,
          day_of_week: day.day_of_week,
          is_available: day.is_available,
          start_time: day.start_time,
          end_time: day.end_time
        })

      copy_breaks(day.breaks, copy.id)
    end)
  end

  defp copy_breaks(breaks, weekly_availability_id) when is_list(breaks) do
    Enum.each(breaks, fn break ->
      AvailabilityBreakQueries.create_break(%{
        weekly_availability_id: weekly_availability_id,
        start_time: break.start_time,
        end_time: break.end_time,
        label: break.label,
        sort_order: break.sort_order
      })
    end)
  end

  defp copy_breaks(_breaks, _weekly_availability_id), do: :ok

  # The UI submits string-keyed params while internal callers use atoms; the
  # merges above need one consistent key type.
  # The slot engine reads these rows and the availability cache is keyed by
  # user, so a mutation here walks profile -> user and clears it. Changing the
  # default or deleting a schedule re-points every meeting type that follows the
  # default, so leaving it to the two-minute TTL would keep offering the old
  # hours to whoever is on the booking page meanwhile. A failed write, or a
  # missing link in the walk, is a no-op: invalidation must never turn a
  # successful edit into an error.
  defp invalidate_cache({:ok, _result} = outcome, %{profile_id: profile_id}) do
    case ProfileQueries.get_profile(profile_id) do
      %{user_id: user_id} -> AvailabilityCache.invalidate_for_user(user_id)
      _no_profile -> :ok
    end

    outcome
  end

  defp invalidate_cache(outcome, _schedule), do: outcome

  defp normalise_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
  end
end
