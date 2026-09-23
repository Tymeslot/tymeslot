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

  alias Ecto.Changeset
  alias Tymeslot.Availability.TimeOffPeriodQueries
  alias Tymeslot.Availability.TimeOffPeriodSchema
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
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
    today = profile_id |> owner() |> owner_today()

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
    can_create?(profile_id, profile_id |> owner() |> owner_today())
  end

  defp can_create?(profile_id, today) do
    TimeOffPeriodQueries.count_for_profile_ending_from(profile_id, today) < @max_periods
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
    owner = owner(profile_id)
    today = owner_today(owner)

    if can_create?(profile_id, today) do
      profile_id
      |> TimeOffPeriodQueries.create(attrs, today: today)
      |> invalidate_cache(owner)
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
    owner = owner(period.profile_id)

    period
    |> TimeOffPeriodQueries.update(attrs, today: owner_today(owner))
    |> invalidate_cache(owner)
  end

  @doc """
  Checks `attrs` without writing anything, as a new period for `profile_id` or
  as an edit of `period`, so a form can show what is wrong while it is still
  being filled in. Applies the same rules `create/2` and `update/2` do, bar
  the per-profile limit.

  A form that already knows the owner's date passes it as `:today`, so
  validating on every change costs no query; saving reads it afresh either way.
  """
  @spec validate(integer() | period(), map(), keyword()) :: Ecto.Changeset.t()
  def validate(period_or_profile_id, attrs, opts \\ [])

  def validate(%TimeOffPeriodSchema{} = period, attrs, opts) do
    today =
      Keyword.get_lazy(opts, :today, fn -> period.profile_id |> owner() |> owner_today() end)

    period
    |> TimeOffPeriodSchema.changeset(attrs, today: today)
    |> Map.put(:action, :validate)
  end

  def validate(profile_id, attrs, opts) when is_integer(profile_id),
    do: validate(%TimeOffPeriodSchema{profile_id: profile_id}, attrs, opts)

  @doc """
  The owner's live bookings that fall inside `period`, soonest first.

  A period only takes days out of *future* availability: bookings already in
  the diary keep their times, stay in the attendees' calendars and keep
  sending reminders. Nothing here refuses or cancels anything, because a host
  entering a holiday over a booking usually means to move that booking
  themselves; the point is that they are told, rather than left to find out.

  Accepts a changeset as well as a stored row, so the form can ask about the
  period as it will be: on an edit that is the submitted attrs merged onto the
  stored row, which is the shape most likely to swallow a booking. A period
  that is incomplete, or that the changeset has already rejected, names no
  interval to ask about and counts nothing.

  The interval is the one `busy_intervals/4` publishes, DST resolution
  included, rather than a comparison of the period's dates against stored UTC
  start times: the dates are wall-clock in the owner's timezone, so comparing
  them directly is a day out for hosts away from UTC, in whichever direction
  their offset runs.
  """
  @spec conflicting_meetings(period() | Changeset.t()) :: [MeetingSchema.t()]
  def conflicting_meetings(%Changeset{valid?: true} = changeset),
    do: changeset |> Changeset.apply_changes() |> conflicting_meetings()

  def conflicting_meetings(%Changeset{}), do: []

  def conflicting_meetings(
        %TimeOffPeriodSchema{starts_on: %Date{}, ends_on: %Date{}, profile_id: profile_id} =
          period
      )
      when is_integer(profile_id),
      do: meetings_within(period, owner(profile_id))

  def conflicting_meetings(%TimeOffPeriodSchema{}), do: []

  defp meetings_within(period, %{user_id: user_id, timezone: timezone})
       when is_integer(user_id) do
    {from, to} = interval(period, timezone || "Etc/UTC")

    # A period whose end lands at or before its start covers no time at all,
    # and a half-open window read backwards would match on the meetings that
    # straddle it rather than the ones inside it.
    if DateTime.before?(from, to) do
      Meetings.list_meetings_in_range_for_organizer(user_id, from, to)
    else
      []
    end
  end

  defp meetings_within(_period, _no_owner), do: []

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
    |> invalidate_cache(owner(period.profile_id))
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

  @doc """
  The stretches `profile_id`'s periods block between `window_start` and
  `window_end`, as UTC `{start, end}` pairs, reading the periods in the owner's
  `timezone`.

  Each period is one continuous interval, so it becomes one pair: from the
  first day at its start time to the last day at its end time, or to midnight
  after the last day when that end is open. A wall-clock time that falls in a
  DST change resolves the way the slot engine resolves breaks, so the feed and
  the booking page agree on where time off begins and ends.
  """
  @spec busy_intervals(integer(), String.t() | nil, DateTime.t(), DateTime.t()) ::
          [{DateTime.t(), DateTime.t()}]
  def busy_intervals(profile_id, timezone, window_start, window_end) do
    timezone = timezone || "Etc/UTC"

    # No timezone is a whole day away from UTC, so a day either side of the
    # window's UTC dates covers every period that can reach into it.
    profile_id
    |> TimeOffPeriodQueries.list_for_profile_in_range(
      Date.add(DateTime.to_date(window_start), -1),
      Date.add(DateTime.to_date(window_end), 1)
    )
    |> Enum.map(&interval(&1, timezone))
    |> Enum.filter(fn {from, to} ->
      DateTime.before?(from, to) and DateTime.before?(from, window_end) and
        DateTime.after?(to, window_start)
    end)
  end

  defp interval(period, timezone) do
    to =
      case period.end_time do
        nil -> utc_wall_clock(Date.add(period.ends_on, 1), ~T[00:00:00], timezone)
        end_time -> utc_wall_clock(period.ends_on, end_time, timezone)
      end

    {utc_wall_clock(period.starts_on, period.start_time || ~T[00:00:00], timezone), to}
  end

  # Mirrors `TimeSlots.resolve_breaks/3`: the first occurrence of a repeated
  # time, the first valid instant after a skipped one. An unknown timezone
  # falls back to UTC, as `today/1` does.
  defp utc_wall_clock(date, time, timezone) do
    local =
      case DateTime.new(date, time, timezone) do
        {:ok, datetime} -> datetime
        {:ambiguous, first, _second} -> first
        {:gap, _before, just_after} -> just_after
        {:error, _unknown_zone} -> DateTime.new!(date, time, "Etc/UTC")
      end

    DateTime.shift_zone!(local, "Etc/UTC")
  end

  # The slot engine reads these rows and the availability cache is keyed by
  # user, so a mutation clears the owner's entries; without that, a holiday
  # entered now would keep being bookable for the cache's TTL. A failed write,
  # or a profile that could not be read, is a no-op: invalidation must never
  # turn a successful edit into an error.
  defp invalidate_cache({:ok, _period} = outcome, %{user_id: user_id}) do
    AvailabilityCache.invalidate_for_user(user_id)
    outcome
  end

  defp invalidate_cache(outcome, _no_owner), do: outcome

  # Read once per operation and threaded through, so a save does not look the
  # same profile up again for its date check and for its cache invalidation.
  defp owner(profile_id), do: ProfileQueries.get_with_user(profile_id)

  defp owner_today(%{timezone: timezone}), do: today(timezone)
  defp owner_today(nil), do: today(nil)
end
