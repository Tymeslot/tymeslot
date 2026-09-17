defmodule Tymeslot.Availability.TimeOff do
  @moduledoc """
  Time off: stretches during which a profile's owner takes no bookings,
  recorded here instead of as blocking events in a connected calendar.

  A period is one continuous interval in the owner's timezone, running from
  `starts_on` at `start_time` to `ends_on` at `end_time`, both dates
  inclusive, with a null time meaning the start or end of that day. Days
  strictly between the two ends are therefore always blocked in full, and the
  times only ever trim the first and last day — the shape "leaving Friday
  lunchtime, back Monday morning" needs, and the shape a whole-day holiday
  degenerates to when both times are null.

  `blocked_window/2` is the single reading of that model: everything else in
  the availability calculation asks this module what a date looks like rather
  than comparing dates and times itself.

  Periods are profile-wide by construction, so they outrank the per-schedule
  date overrides: a day covered in full by time off offers nothing, even where
  an override marked that same date `available`. "I am away" is a statement
  about the person and cannot be contradicted by one schedule's exception.
  """

  alias Tymeslot.Availability.TimeOffPeriodQueries
  alias Tymeslot.Availability.TimeOffPeriodSchema
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Utils.DateTimeUtils

  @typedoc """
  What a period does to one date: nothing, blocks the whole of it, or blocks
  the single `{start_time, end_time}` window it trims out of it.
  """
  @type blocked_window :: :none | :all_day | {Time.t(), Time.t()}

  @type period :: TimeOffPeriodSchema.t()
  @type result :: {:ok, period()} | {:error, Ecto.Changeset.t()}

  # The last instant a wall-clock day can name. Slot generation already treats
  # 23:59:59 as the end of a day (see `TimeSlots.determine_slot_range/5`), so
  # an open-ended period ends where the longest possible business-hours window
  # does and cannot leave a sliver of bookable evening behind.
  @end_of_day ~T[23:59:59]

  # A profile with more periods than this is not describing holidays any more,
  # and the availability read path holds every overlapping period in memory.
  # Only periods that have not ended count: finished ones never reach that path,
  # and counting them would lock an account out once enough holidays had passed.
  @max_periods 100

  # How far back finished periods stay listed. Older ones affect nothing and
  # would only push the upcoming ones down the page.
  @recent_past_days 30

  @doc """
  Maximum number of periods one profile may hold that have not yet ended.
  """
  @spec max_periods() :: pos_integer()
  def max_periods, do: @max_periods

  @doc """
  Lists a profile's periods, soonest-starting first.
  """
  @spec list(integer()) :: [period()]
  def list(profile_id), do: TimeOffPeriodQueries.list_for_profile(profile_id)

  @doc """
  Days back that finished periods are still listed by `list_by_status/1`.
  """
  @spec recent_past_days() :: pos_integer()
  def recent_past_days, do: @recent_past_days

  @doc """
  A profile's periods split by whether they are over, as the dashboard lists
  them.

  `:current` holds every period whose last day is today or later, soonest
  first, including one already under way. `:past` holds those that ended
  within `recent_past_days/0`, most recently ended first; anything older is
  left out.
  """
  @spec list_by_status(integer()) :: %{current: [period()], past: [period()]}
  def list_by_status(profile_id) do
    today = owner_today(profile_id)

    {past, current} =
      profile_id
      |> TimeOffPeriodQueries.list_for_profile_ending_from(Date.add(today, -@recent_past_days))
      |> Enum.split_with(&ended?(&1, today))

    %{current: current, past: Enum.sort_by(past, & &1.ends_on, {:desc, Date})}
  end

  @doc """
  Whether `period` finished before `today`, so no longer affects availability.
  """
  @spec ended?(period(), Date.t()) :: boolean()
  def ended?(%{ends_on: ends_on}, today), do: Date.compare(ends_on, today) == :lt

  @doc """
  Whether the profile may add another period.
  """
  @spec can_create?(integer()) :: boolean()
  def can_create?(profile_id) do
    TimeOffPeriodQueries.count_for_profile_ending_from(profile_id, owner_today(profile_id)) <
      @max_periods
  end

  @doc """
  Creates a period for a profile.

  Returns `{:error, :limit_reached}` rather than a changeset when the profile
  already holds `max_periods/0`, so the caller can say why without inventing a
  field to hang the message on. Neither date may fall before `today/1` in the
  owner's timezone.
  """
  @spec create(integer(), map()) :: result() | {:error, :limit_reached}
  def create(profile_id, attrs) do
    if can_create?(profile_id) do
      attrs
      |> normalise_attrs()
      |> Map.put(:profile_id, profile_id)
      |> TimeOffPeriodQueries.create(today: owner_today(profile_id))
      |> invalidate_cache(profile_id)
    else
      {:error, :limit_reached}
    end
  end

  @doc """
  Updates a period.

  A date the update changes may not fall before `today/1`; a date it leaves
  alone may, so a period already under way stays editable.
  """
  @spec update(period(), map()) :: result()
  def update(%TimeOffPeriodSchema{} = period, attrs) do
    period
    |> TimeOffPeriodQueries.update(normalise_attrs(attrs), today: owner_today(period.profile_id))
    |> invalidate_cache(period.profile_id)
  end

  @doc """
  Checks `attrs` without writing anything, as a new period for `profile_id` or
  as an edit of `period`, so a form can show what is wrong while it is still
  being filled in. Applies the same rules `create/2` and `update/2` do, bar
  the per-profile limit.
  """
  @spec validate(integer() | period(), map()) :: Ecto.Changeset.t()
  def validate(%TimeOffPeriodSchema{} = period, attrs) do
    period
    |> TimeOffPeriodSchema.changeset(normalise_attrs(attrs),
      today: owner_today(period.profile_id)
    )
    |> Map.put(:action, :validate)
  end

  def validate(profile_id, attrs) when is_integer(profile_id),
    do: validate(%TimeOffPeriodSchema{profile_id: profile_id}, attrs)

  @doc """
  The current date in `timezone`, the earliest day a period may be placed on.

  Read in the owner's timezone because that is the one the period's dates are
  in: late on the 17th in Berlin is already the 18th in Tokyo. A missing or
  unknown timezone falls back to UTC.
  """
  @spec today(String.t() | nil) :: Date.t()
  def today(nil), do: Clock.utc_today()
  def today(timezone), do: timezone |> DateTimeUtils.now_in_timezone() |> DateTime.to_date()

  @doc """
  Deletes a period.
  """
  @spec delete(period()) :: result()
  def delete(%TimeOffPeriodSchema{} = period) do
    period
    |> TimeOffPeriodQueries.delete()
    |> invalidate_cache(period.profile_id)
  end

  @doc """
  Fetches one of a profile's periods.

  Scoped by profile rather than by id alone so a submitted id can never reach
  another account's row.
  """
  @spec fetch(integer(), integer()) :: {:ok, period()} | {:error, :not_found}
  def fetch(profile_id, id) do
    case TimeOffPeriodQueries.get_for_profile(profile_id, id) do
      nil -> {:error, :not_found}
      period -> {:ok, period}
    end
  end

  @doc """
  What `period` does to `date`.

  Returns `:none` when the date falls outside the period, `:all_day` when the
  period covers the whole of it, and `{start_time, end_time}` for the window
  it trims off an otherwise ordinary day.
  """
  @spec blocked_window(period() | map(), Date.t()) :: blocked_window()
  def blocked_window(%{starts_on: nil}, _date), do: :none
  def blocked_window(%{ends_on: nil}, _date), do: :none

  def blocked_window(%{starts_on: starts_on, ends_on: ends_on} = period, date) do
    if Date.compare(date, starts_on) == :lt or Date.compare(date, ends_on) == :gt do
      :none
    else
      window_within_period(period, date, starts_on, ends_on)
    end
  end

  def blocked_window(_period, _date), do: :none

  defp window_within_period(period, date, starts_on, ends_on) do
    from = if date == starts_on, do: period.start_time || ~T[00:00:00], else: ~T[00:00:00]
    to = if date == ends_on, do: period.end_time || @end_of_day, else: @end_of_day

    cond do
      # A first day whose start time is at or past the last day's end time
      # leaves nothing: a single-day period is guarded by the changeset, but a
      # multi-day one is free to end earlier in the clock than it began.
      Time.compare(from, to) != :lt -> :none
      from == ~T[00:00:00] and to == @end_of_day -> :all_day
      true -> {from, to}
    end
  end

  @doc """
  Whether `periods` block the whole of `date`.
  """
  @spec all_day?([period()], Date.t()) :: boolean()
  def all_day?(periods, date) when is_list(periods) do
    Enum.any?(periods, &(blocked_window(&1, date) == :all_day))
  end

  @doc """
  The part-day windows `periods` block on `date`, as the
  `{start_time, end_time}` tuples the slot generator already excludes breaks
  with.

  Days blocked in full contribute nothing here: `all_day?/2` answers those,
  and a whole day is refused before slot generation rather than by removing
  every slot it produced.
  """
  @spec windows_for_day([period()], Date.t()) :: [{Time.t(), Time.t()}]
  def windows_for_day(periods, date) when is_list(periods) do
    Enum.flat_map(periods, fn period ->
      case blocked_window(period, date) do
        {_from, _to} = window -> [window]
        _all_day_or_none -> []
      end
    end)
  end

  # The slot engine reads these rows and the availability cache is keyed by
  # user, so a mutation walks profile -> user and clears it; without that, a
  # holiday entered now would keep being bookable for the cache's TTL. A failed
  # write, or a missing link in the walk, is a no-op: invalidation must never
  # turn a successful edit into an error.
  defp invalidate_cache({:ok, _period} = outcome, profile_id) do
    case ProfileQueries.get_with_user(profile_id) do
      %{user_id: user_id} -> AvailabilityCache.invalidate_for_user(user_id)
      _no_profile -> :ok
    end

    outcome
  end

  defp invalidate_cache(outcome, _profile_id), do: outcome

  defp owner_today(profile_id) do
    case ProfileQueries.get_with_user(profile_id) do
      %{timezone: timezone} -> today(timezone)
      nil -> today(nil)
    end
  end

  # The UI submits string-keyed params while internal callers use atoms; the
  # profile_id merge above needs one consistent key type.
  defp normalise_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
  end
end
