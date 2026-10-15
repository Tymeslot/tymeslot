defmodule Tymeslot.Availability.Offer do
  @moduledoc """
  The times a public booking page offers.

  Answers the three questions the booking page asks: which times are free on
  one date (`slots_for_date/3`), which times are free on every day of a range
  (`slots_for_range/4`, for a week view), and which days in a range have any
  free time at all (`days_in_range/4`). All three build their rules from
  `config/4`, which rests
  on `Tymeslot.Availability.Schedules.config/2`, the same rules the booking
  submit re-checks against (`Tymeslot.Bookings.Policy.scheduling_config/2`).
  A time offered here is therefore a time the submit accepts.

  For a group meeting type the offer is seat-aware: each time carries how
  many seats are left, a live meeting with a seat free stays bookable at its
  own time, and a full one is dropped (see
  `Tymeslot.Availability.GroupSlots`).

  Every question is answered against the same busy set: the host's connected
  calendars, merged with the host's own live bookings. The bookings are what
  stop the two paths disagreeing, because the submit refuses from the meetings
  table and would otherwise reject a slot this module had just offered; see
  `Tymeslot.Meetings.BusyPeriods`.

  Works on a plain request map rather than a socket, so a fetch task can
  capture it whole and nothing here depends on the web layer.
  """

  alias Tymeslot.Availability.{Calculate, GroupSlots, Reach, Schedules, TimeSlots}
  alias Tymeslot.Bookings.{Orchestrator, RescheduleSeat}
  alias Tymeslot.Demo
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles

  # A day. The duration can come from a URL slug, which is visitor input, so an
  # unbounded parse would let `/:username/99999/book` hold a multi-day slot.
  @max_duration_minutes Reach.max_meeting_minutes()
  @default_duration_minutes 30

  # How far outside the dates being rendered the booking fetch reaches. A
  # slot starting on the last rendered date can run for up to a day and keep
  # its buffer after it, and the window's own bounds are UTC while the days
  # are the booker's, up to a timezone offset away; nothing further out can
  # touch a slot inside.
  @busy_window_padding_days Reach.utc_padding_days()

  # The longest range `slots_for_range/4` answers: six weeks, the month grid's
  # display range. A week view asks for seven days; the bound keeps a caller's
  # mistake from computing a year of slots.
  @max_range_days 42

  @typedoc """
  What a booking page is showing, and to whom.

    * `:profile` - the organiser's profile. Its `user_id` is whose calendar and
      bookings are read, so the organiser cannot be named separately from the
      profile and the two cannot disagree.
    * `:user_timezone` - the booker's timezone.
    * `:meeting_type` - the resolved meeting type, or nil before one is chosen.
    * `:reschedule_uid` - the meeting a reschedule page is moving, as the link
      named it. The meeting counts neither against the host's booking limits
      nor as a calendar conflict with itself, exactly as
      `Tymeslot.Bookings.Reschedule` leaves it out of both when the move is
      submitted, but only once it is proven to be a movable meeting of this
      organiser; any other value is ignored.
    * `:reschedule_seat_token` - the group seat a seat-move page is moving.
      Its meeting is left out the same way, but only when the seat is that
      meeting's last live one, which is when `Tymeslot.Bookings.RescheduleSeat`
      cancels it with the move and leaves it out on submit; with other seats
      on it, the meeting keeps its time and stays busy. Wins over
      `:reschedule_uid`, as it does on submit.
    * `:demo_mode?` - whether the page is running as a demo.
    * `:debug_calendar_module` - a calendar module override, for development.
  """
  @type request :: %{
          required(:profile) => %{required(:user_id) => integer(), optional(atom()) => any()},
          required(:user_timezone) => String.t(),
          optional(:meeting_type) => map() | nil,
          optional(:reschedule_uid) => String.t() | nil,
          optional(:reschedule_seat_token) => String.t() | nil,
          optional(:demo_mode?) => boolean() | nil,
          optional(:debug_calendar_module) => module() | nil
        }

  @doc """
  The times free on `date_string` (ISO 8601) for a meeting of `duration`.

  Times come back as display strings, except for a group meeting type, whose
  times are `GroupSlots.slot()` maps carrying the seats each has left. Each
  time is listed under the date it starts on, even when the meeting ends the
  next day, so the date and the label together name the instant.
  `duration` is bounded as in `duration_minutes/2`. Returns `{:error, reason}`
  for a date that does not parse and when the organiser's calendar cannot be
  read.
  """
  @spec slots_for_date(request(), String.t(), String.t() | integer() | nil) ::
          {:ok, [term()]} | {:error, any()}
  def slots_for_date(%{profile: %{user_id: user_id} = profile} = request, date_string, duration) do
    with {:ok, date} <- Date.from_iso8601(date_string) do
      if demo?(request) do
        Demo.get_available_slots(
          date_string,
          duration,
          request.user_timezone,
          user_id,
          profile,
          context(request)
        )
      else
        free_slots(request, date, duration)
      end
    end
  end

  @doc """
  The times free on every day of `start_date..end_date` (inclusive) for a
  meeting of `duration`, as a map of ISO 8601 date strings to that day's
  slots. Every day of the range is a key; a day with nothing free maps to
  `[]`.

  Each day's list is exactly what `slots_for_date/3` returns for that day: the
  days run through the same slot engine with the same rules and the same busy
  set, but the host's calendar, their booking-limit counts, the meeting being
  rescheduled and the schedule's overrides and time off are read once for the
  whole range instead of once per day. A demo page answers each day from the
  demo provider, as `slots_for_date/3` does.

  Returns `{:error, :invalid_range}` when `end_date` is before `start_date`,
  `{:error, :range_too_long}` for a range of more than #{@max_range_days} days,
  and `{:error, reason}` when the organiser's calendar cannot be read.
  """
  @spec slots_for_range(request(), Date.t(), Date.t(), String.t() | integer() | nil) ::
          {:ok, %{String.t() => [term()]}} | {:error, any()}
  def slots_for_range(request, %Date{} = start_date, %Date{} = end_date, duration) do
    cond do
      Date.compare(start_date, end_date) == :gt ->
        {:error, :invalid_range}

      Date.diff(end_date, start_date) >= @max_range_days ->
        {:error, :range_too_long}

      demo?(request) ->
        collect_days(start_date, end_date, fn date ->
          slots_for_date(request, Date.to_iso8601(date), duration)
        end)

      true ->
        free_slots_in_range(request, start_date, end_date, duration)
    end
  end

  @doc """
  Which days in `start_date..end_date` (inclusive) have at least one free
  time, as a map of ISO 8601 date strings to booleans.

  Computed against the organiser's real calendar and bookings, so a fully
  booked day comes back `false`. Results are cached per range; calendar
  failures are not, so the next request retries them.
  """
  @spec days_in_range(request(), Date.t(), Date.t(), pos_integer() | nil) ::
          {:ok, %{String.t() => boolean()}} | {:error, any()}
  def days_in_range(
        %{profile: %{user_id: user_id} = profile} = request,
        start_date,
        end_date,
        duration_minutes
      ) do
    if demo?(request) do
      Demo.get_range_availability(
        user_id,
        start_date,
        end_date,
        request.user_timezone,
        profile,
        context(request),
        duration_minutes
      )
    else
      free_days(request, start_date, end_date, duration_minutes)
    end
  end

  @doc """
  The meeting length a booking is made for, in minutes.

  The resolved meeting type's current duration is authoritative. Only when
  there is none does `fallback` (a duration slug such as `"30min"`, or a
  persisted length in minutes) decide, and that is bounded to a day, with
  anything unparseable resolving to #{@default_duration_minutes} minutes.

  The booking page, the booking submit and the reschedule submit all resolve
  the duration here, so the grid a time was offered from and the grid it is
  checked against cannot be stepped differently.
  """
  @spec duration_minutes(map() | nil, String.t() | integer() | nil) :: pos_integer()
  def duration_minutes(%{duration_minutes: minutes}, _fallback) when is_integer(minutes),
    do: minutes

  def duration_minutes(_meeting_type, fallback), do: bounded_duration(fallback)

  @doc """
  The config the slot engine computes a page's offer from: the scheduling
  rules of `Schedules.config/2`, plus the booking-limit check and the meeting
  length.
  """
  @spec config(
          Schedules.schedule() | nil,
          map() | nil,
          (DateTime.t() -> boolean()) | nil,
          pos_integer() | nil
        ) :: map()
  def config(schedule, meeting_type, limit_checker, duration_minutes) do
    schedule
    |> Schedules.config(meeting_type)
    |> Map.merge(%{limit_checker: limit_checker, duration_minutes: duration_minutes})
  end

  defp free_slots(%{profile: %{user_id: user_id} = profile} = request, date, duration) do
    moving = moving_meeting(request)

    with {:ok, events} <-
           CalendarEvents.get_calendar_events_from_context(
             date,
             user_id,
             calendar_context(request)
           ) do
      duration_minutes = bounded_duration(duration)
      meeting_type = request[:meeting_type]

      limit_checker = limit_checker(request, moving_uid(moving), date, date)

      config =
        meeting_type
        |> Schedules.resolve_for(profile)
        |> config(meeting_type, limit_checker, duration_minutes)

      busy = busy_periods(events, user_id, date, date, moving)

      with {:ok, starts} <-
             Calculate.available_starts(
               date,
               duration_minutes,
               request.user_timezone,
               owner_timezone(profile),
               busy,
               config
             ) do
        {:ok,
         offered_slots(starts, meeting_type, date, %{
           user_timezone: request.user_timezone,
           owner_timezone: owner_timezone(profile),
           events: busy,
           config: config
         })}
      end
    end
  end

  # `free_slots/3` for every day of a range, with everything that does not
  # depend on the day read once: the calendar (whose fetch covers the whole
  # booking window whatever date it is given), the proven reschedule meeting,
  # the booking-limit counts over the range, and the schedule's weekly hours,
  # overrides and time off for the range and a day either side, which
  # `Calculate.available_starts/6` then finds already in the config. The busy
  # set is merged over the range, so each day sees every booking and event
  # that `free_slots/3` would merge for it alone.
  defp free_slots_in_range(
         %{profile: %{user_id: user_id} = profile} = request,
         start_date,
         end_date,
         duration
       ) do
    moving = moving_meeting(request)

    with {:ok, events} <-
           CalendarEvents.get_calendar_events_from_context(
             start_date,
             user_id,
             calendar_context(request)
           ) do
      duration_minutes = bounded_duration(duration)
      meeting_type = request[:meeting_type]
      limit_checker = limit_checker(request, moving_uid(moving), start_date, end_date)

      config =
        meeting_type
        |> Schedules.resolve_for(profile)
        |> config(meeting_type, limit_checker, duration_minutes)

      config =
        Calculate.prefetch_schedule_data(
          config,
          config.schedule_id,
          Date.add(start_date, -1),
          Date.add(end_date, 1)
        )

      busy = busy_periods(events, user_id, start_date, end_date, moving)

      group_context = %{
        user_timezone: request.user_timezone,
        owner_timezone: owner_timezone(profile),
        events: busy,
        config: config
      }

      collect_days(start_date, end_date, fn date ->
        with {:ok, starts} <-
               Calculate.available_starts(
                 date,
                 duration_minutes,
                 request.user_timezone,
                 owner_timezone(profile),
                 busy,
                 config
               ) do
          {:ok, offered_slots(starts, meeting_type, date, group_context)}
        end
      end)
    end
  end

  # `day_slots` for every day of the range, keyed by ISO date; the first day
  # that fails fails the range.
  defp collect_days(start_date, end_date, day_slots) do
    start_date
    |> Date.range(end_date)
    |> Enum.reduce_while({:ok, %{}}, fn date, {:ok, acc} ->
      case day_slots.(date) do
        {:ok, slots} -> {:cont, {:ok, Map.put(acc, Date.to_iso8601(date), slots)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp free_days(
         %{profile: %{user_id: user_id} = profile} = request,
         start_date,
         end_date,
         duration_minutes
       ) do
    meeting_type = request[:meeting_type]
    moving = moving_meeting(request)
    moving_uid = moving_uid(moving)

    # Keyed on the proven uid only, so a mover's view is never served to
    # anyone else and an arbitrary link value cannot mint an entry of its own.
    cache_key =
      AvailabilityCache.availability_range_key(
        user_id,
        start_date,
        end_date,
        request.user_timezone,
        duration_minutes,
        meeting_type && meeting_type.id,
        moving_uid
      )

    AvailabilityCache.get_or_compute_events(cache_key, fn ->
      with {:ok, events} <- booking_window_events(request, start_date) do
        config =
          meeting_type
          |> Schedules.resolve_for(profile)
          |> config(
            meeting_type,
            limit_checker(request, moving_uid, start_date, end_date),
            duration_minutes || @default_duration_minutes
          )

        busy = busy_periods(events, user_id, start_date, end_date, moving)

        with {:ok, base_map} <-
               Calculate.range_availability(
                 start_date,
                 end_date,
                 owner_timezone(profile),
                 request.user_timezone,
                 busy,
                 config
               ) do
          {:ok,
           GroupSlots.overlay_range(base_map, meeting_type, start_date, end_date, %{
             user_timezone: request.user_timezone,
             owner_timezone: owner_timezone(profile),
             events: busy,
             config: config
           })}
        end
      end
    end)
  end

  # Only a group type's times carry seat counts; everything else is the plain
  # labels the booking page has always read. Every start is listed under the
  # date it begins on, so a bare label plus the page's date is the instant.
  defp offered_slots(starts, %MeetingTypeSchema{} = meeting_type, date, context) do
    if MeetingTypeSchema.group?(meeting_type),
      do: GroupSlots.enrich_day_slots(starts, meeting_type, date, context),
      else: labels(starts)
  end

  defp offered_slots(starts, _meeting_type, _date, _context), do: labels(starts)

  defp labels(starts), do: Enum.map(starts, &TimeSlots.format_datetime_slot/1)

  # The provider fetch behind this is window-shaped, not month-shaped:
  # `Events.get_calendar_events/3` ignores the date it is given and always asks
  # for `today .. today + advance_booking_days`. Folding it under a key built
  # from the 42-day *display* range would therefore store the same event list
  # once per rendered month and guarantee a miss for anything that moves the
  # calendar, worst of all the next-available forward search, which re-enters
  # `days_in_range/4` once per hop and would otherwise buy an identical round
  # trip to the host's calendar each time, on exactly the fully booked hosts
  # the search exists to help.
  #
  # So the events get their own entry, keyed on the user alone because that is
  # the fetch's entire input. The folded map keeps its display-range key: the
  # fold is what actually differs between hops.
  #
  # Errors stay uncached, for the reason `get_or_compute_events/2` exists at
  # all: a timed-out calendar must be retried on the next request, not pinned
  # empty for the TTL. `AvailabilityCache.invalidate_for_user/1` drops this
  # entry with the folded maps, so a calendar sync cannot leave the two
  # disagreeing about how fresh they are.
  defp booking_window_events(%{profile: %{user_id: user_id}} = request, start_date) do
    AvailabilityCache.get_or_compute_events(
      AvailabilityCache.booking_window_events_key(user_id),
      fn ->
        CalendarEvents.get_calendar_events_from_context(
          start_date,
          user_id,
          calendar_context(request)
        )
      end
    )
  end

  # Everything that occupies the host's time across `first_date..last_date`:
  # their connected calendars, plus their own live bookings, which reach the
  # page this way rather than waiting to be mirrored onto a provider calendar
  # (see `Tymeslot.Meetings.BusyPeriods`). `moving` is then excluded from the
  # merged set, dropping the rescheduling meeting along with its mirror so that
  # a booking is never a conflict with itself.
  defp busy_periods(events, user_id, first_date, last_date, moving) do
    events
    |> Meetings.merge_busy_periods(
      user_id,
      utc_day_start(Date.add(first_date, -@busy_window_padding_days)),
      utc_day_start(Date.add(last_date, 1 + @busy_window_padding_days))
    )
    |> Meetings.reject_calendar_event_mirrors(moving)
  end

  defp utc_day_start(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  # Nil when the host has no booking limits configured, keeping the common path
  # free of extra queries. The dates are the booker's, so the counts cover
  # every host date a slot under them can fall on. The meeting being moved is
  # left out of the counts, exactly as the reschedule submit leaves it out.
  defp limit_checker(
         %{profile: %{user_id: user_id} = profile} = request,
         moving_uid,
         start_date,
         end_date
       ) do
    Checker.build_slot_checker(
      user_id,
      profile,
      request[:meeting_type],
      start_date,
      end_date,
      exclude_uid: moving_uid,
      booker_timezone: request.user_timezone
    )
  end

  # The meeting a reschedule page is moving, once
  # `Orchestrator.get_meeting_for_reschedule/2` proves it is this organiser's
  # and still movable (the lookup the submit's own flow relies on); nil for
  # anything else. The link parameter is visitor input, so it is never used
  # unverified.
  #
  # The whole record, not just its uid, because the page has to leave the
  # meeting out of two different counts: the host's booking limits, keyed on
  # the uid, and the events read back from their connected calendar, where the
  # meeting appears as the provider event Tymeslot wrote and is matched by
  # whichever identifier that provider family preserves.
  #
  # A seat move vacates its meeting only when the mover is its last seat;
  # `RescheduleSeat.vacated_meeting/2` is the submit's own rule for that.
  defp moving_meeting(%{reschedule_seat_token: token, profile: %{user_id: user_id}})
       when is_binary(token) and is_integer(user_id),
       do: RescheduleSeat.vacated_meeting(token, user_id)

  defp moving_meeting(%{reschedule_uid: uid, profile: %{user_id: user_id}})
       when is_binary(uid) and is_integer(user_id) do
    case Orchestrator.get_meeting_for_reschedule(uid, user_id) do
      {:ok, meeting} -> meeting
      {:error, _not_movable} -> nil
    end
  end

  defp moving_meeting(_request), do: nil

  defp moving_uid(nil), do: nil
  defp moving_uid(%{uid: uid}), do: uid

  defp demo?(%{profile: profile} = request) do
    Demo.demo_profile?(profile) || request[:demo_mode?] == true
  end

  # The context map the calendar fetch reads. Its contract names these two keys
  # only, so the demo provider's extra keys stay out of it.
  defp calendar_context(%{profile: profile} = request) do
    %{organizer_profile: profile, debug_calendar_module: request[:debug_calendar_module]}
  end

  # The context map the demo provider reads.
  defp context(request) do
    request
    |> calendar_context()
    |> Map.merge(%{demo_mode: request[:demo_mode?] == true, meeting_type: request[:meeting_type]})
  end

  defp owner_timezone(profile), do: profile.timezone || Profiles.get_default_timezone()

  defp bounded_duration(minutes) when is_integer(minutes) and minutes > 0,
    do: min(minutes, @max_duration_minutes)

  defp bounded_duration(slug) when is_binary(slug),
    do: slug |> TimeSlots.parse_duration() |> min(@max_duration_minutes)

  defp bounded_duration(_other), do: @default_duration_minutes
end
