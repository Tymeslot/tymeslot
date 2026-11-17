defmodule Tymeslot.Availability.Offer do
  @moduledoc """
  The times a public booking page offers.

  Answers the three questions the booking page asks: which times are free on
  one date (`slots_for_date/3`), which times are free on every day of a range
  (`slots_for_range/4`, for a week view), and which days in a range have any
  free time at all (`days_in_range/4`). All three build their rules from
  `config/4`, which rests
  on `Tymeslot.Availability.Schedules.config/2`, the same rules the booking
  submit re-checks against (`Tymeslot.Bookings.Schedules.booking_config/2`).
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

  alias Tymeslot.Availability.{BusyIntervals, Calculate, GroupSlots, Schedules, SessionSlots}
  alias Tymeslot.Availability.Offer.{HostCalendar, Moving, Range, Request}
  alias Tymeslot.Demo
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes.FixedDates
  alias Tymeslot.MeetingTypes.Lengths
  alias Tymeslot.Scheduling.{RescheduleContext, SeatMoveContext}

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
    * `:reschedule` - the same meeting, already loaded by
      `Tymeslot.Scheduling.ThemeFlow.reschedule_context/2`, which proved it
      the organiser's and movable when the page applied its link. Used in
      place of looking `:reschedule_uid` up again on every fetch, provided it
      is the meeting that uid names and this organiser's.
    * `:reschedule_seat_token` - the group seat a seat-move page is moving.
      Its meeting is left out the same way, but only when the seat is that
      meeting's last live one, which is when `Tymeslot.Bookings.RescheduleSeat`
      cancels it with the move and leaves it out on submit; with other seats
      on it, the meeting keeps its time and stays busy. Wins over
      `:reschedule_uid`, as it does on submit.
    * `:seat_move` - the same seat, already loaded by
      `Tymeslot.Scheduling.ThemeFlow.seat_move_context/2` when the page
      applied its link. Used in place of looking the token up again on every
      fetch, provided it is the seat that token names; whether the move
      vacates its meeting is still decided afresh.
    * `:demo_mode?` - whether the page is running as a demo.
    * `:window_until` - a `Date` the slots may reach past the schedule's
      booking window: a series' later sessions, which the window does not
      bind once the first lies inside it (`Tymeslot.BookingSeries.Check`).
      The notice still applies, and the host's calendar is read over the
      range itself. A reschedule of a series session reaches as far as its
      context says (`Offer.Moving.with_reach/1`) without naming it here.
    * `:cached_calendar` - read a range's calendar through the cache
      (`Offer.HostCalendar`), as a preview may; a booking page reads it fresh.
  """
  @type request :: %{
          required(:profile) => %{required(:user_id) => integer(), optional(atom()) => any()},
          required(:user_timezone) => String.t(),
          optional(:meeting_type) => map() | nil,
          optional(:reschedule_uid) => String.t() | nil,
          optional(:reschedule) => RescheduleContext.t() | nil,
          optional(:reschedule_seat_token) => String.t() | nil,
          optional(:seat_move) => SeatMoveContext.t() | nil,
          optional(:demo_mode?) => boolean() | nil,
          optional(:cached_calendar) => boolean(),
          optional(:window_until) => Date.t()
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
      cond do
        FixedDates.sessions?(request[:meeting_type]) ->
          {:ok, SessionSlots.day_slots(request.meeting_type, date, request.user_timezone)}

        Request.demo?(request) ->
          Demo.get_available_slots(
            date_string,
            duration,
            request.user_timezone,
            user_id,
            profile,
            Request.demo_context(request)
          )

        true ->
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
  `{:error, :range_too_long}` for a range of more than 42 days (`Range.max_range_days/0`),
  and `{:error, reason}` when the organiser's calendar cannot be read.
  """
  @spec slots_for_range(request(), Date.t(), Date.t(), String.t() | integer() | nil) ::
          {:ok, %{String.t() => [term()]}} | {:error, any()}
  def slots_for_range(request, %Date{} = start_date, %Date{} = end_date, duration) do
    with {:ok, %{slots: slots}} <-
           slots_and_busy_for_range(request, start_date, end_date, duration) do
      {:ok, slots}
    end
  end

  @doc """
  `slots_for_range/4` together with the busy periods those slots were computed
  from, for a view that shows both (a week preview).

  The host's calendar is read once for the pair, so the free times and the busy
  blocks cannot disagree and a caller does not pay two provider round trips.
  `:starts` holds the same free times as `DateTime`s in the booker's zone.
  `:busy` is every period that occupies the host's time in the range (blocking
  calendar events and live bookings) as UTC `{start, end}` instants, unmerged,
  buffers and notice not applied. `:windows` is the hours the host is actually
  open on each date of the range: what `BusinessHours.owner_windows/4` resolves
  (overrides, extra windows and overnight hours included) with time off taken
  out, so a date wholly away has none and a part-day period can leave a window
  in two pieces. A demo page has no starts, busy periods or windows. Fails
  exactly as `slots_for_range/4` does.
  """
  @spec slots_and_busy_for_range(
          request(),
          Date.t(),
          Date.t(),
          String.t() | integer() | nil
        ) :: {:ok, BusyIntervals.range_view()} | {:error, any()}
  def slots_and_busy_for_range(request, %Date{} = start_date, %Date{} = end_date, duration) do
    with :ok <- Range.check_range(start_date, end_date) do
      if Request.demo?(request) do
        with {:ok, slots} <-
               Range.collect_days(start_date, end_date, fn date ->
                 slots_for_date(request, Date.to_iso8601(date), duration)
               end) do
          {:ok, %{slots: slots, starts: %{}, busy: [], windows: []}}
        end
      else
        Range.slots_and_busy_in_range(request, start_date, end_date, duration)
      end
    end
  end

  @doc """
  The instants a meeting of `duration` can start at on every day of
  `start_date..end_date` (inclusive), keyed by the booker's date (in
  `request.user_timezone`): the starts `slots_for_range/4` labels, before
  any labelling. Every day of the range is a key; a day with nothing free
  maps to `[]`.

  The organiser's calendar reads its bookable windows from here
  (`Tymeslot.Availability.bookable_windows/4`), so the calendar and the
  booking page cannot disagree. A group type's live sessions with a seat
  free are not added: a start is listed only where a new meeting fits, so a
  fixed-date type (`Tymeslot.MeetingTypes.FixedDates`), whose planned
  sessions are joined and never started, lists none. A demo request is
  answered from the real engine like any other.

  `opts[:events]` picks where the host's calendar is read from: `:fresh`
  (the default, what `slots_for_range/4` does) asks the calendar, `:cached`
  reads the cached booking-window events `slots_for_date/3` uses, so the two
  agree.

  Returns the errors `slots_for_range/4` does.
  """
  @spec starts_in_range(
          request(),
          Date.t(),
          Date.t(),
          String.t() | integer() | nil,
          [{:events, :fresh | :cached}]
        ) :: {:ok, %{Date.t() => [DateTime.t()]}} | {:error, any()}
  defdelegate starts_in_range(request, start_date, end_date, duration, opts \\ []), to: Range

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
    cond do
      FixedDates.sessions?(request[:meeting_type]) ->
        {:ok,
         SessionSlots.days(request.meeting_type, start_date, end_date, request.user_timezone)}

      Request.demo?(request) ->
        Demo.get_range_availability(
          user_id,
          start_date,
          end_date,
          request.user_timezone,
          profile,
          Request.demo_context(request),
          duration_minutes
        )

      true ->
        free_days(request, start_date, end_date, duration_minutes)
    end
  end

  @doc """
  The meeting length a booking is made for, in minutes.

  The resolved meeting type's current duration is authoritative, or `chosen`
  when the type offers that length among several
  (`Tymeslot.MeetingTypes.Lengths`); a length it does not offer is ignored.
  Only when there is no type does `fallback` (a duration slug such as `"30min"`, or a
  persisted length in minutes) decide, and that is bounded to a day, with
  anything unparseable resolving to the default length
  (`Offer.Request.default_duration_minutes/0`).

  The booking page, the booking submit and the reschedule submit all resolve
  the duration here, so the grid a time was offered from and the grid it is
  checked against cannot be stepped differently.
  """
  @spec duration_minutes(map() | nil, String.t() | integer() | nil, term()) :: pos_integer()
  def duration_minutes(meeting_type, fallback, chosen \\ nil)

  def duration_minutes(%{duration_minutes: minutes} = meeting_type, _fallback, chosen)
      when is_integer(minutes) do
    case Lengths.resolve(meeting_type, chosen) do
      resolved when is_integer(resolved) -> resolved
      nil -> minutes
    end
  end

  def duration_minutes(_meeting_type, fallback, _chosen), do: Request.bounded_duration(fallback)

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
  defdelegate config(schedule, meeting_type, limit_checker, duration_minutes), to: Request

  defp free_slots(%{profile: %{user_id: user_id} = profile} = request, date, duration) do
    request = Moving.with_reach(request)
    moving = Moving.meeting(request)

    with {:ok, events} <- HostCalendar.for_window(request, {date, date}) do
      duration_minutes = Request.bounded_duration(duration)
      meeting_type = request[:meeting_type]

      limit_checker = Request.limit_checker(request, Moving.uid(moving), date, date)

      config =
        meeting_type
        |> Schedules.resolve_for(profile)
        |> Request.config(meeting_type, limit_checker, duration_minutes)
        |> Request.reach_until(request)

      busy = Request.busy_periods(events, user_id, date, date, moving)

      with {:ok, starts} <-
             Calculate.available_starts(
               date,
               duration_minutes,
               request.user_timezone,
               Request.owner_timezone(profile),
               busy,
               config
             ) do
        {:ok,
         Request.offered_slots(starts, meeting_type, date, %{
           user_timezone: request.user_timezone,
           owner_timezone: Request.owner_timezone(profile),
           events: busy,
           config: config
         })}
      end
    end
  end

  defp free_days(
         %{profile: %{user_id: user_id} = profile} = request,
         start_date,
         end_date,
         duration_minutes
       ) do
    request = Moving.with_reach(request)
    meeting_type = request[:meeting_type]
    moving = Moving.meeting(request)
    moving_uid = Moving.uid(moving)

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
      with {:ok, events} <- HostCalendar.for_window(request, {start_date, end_date}) do
        config =
          meeting_type
          |> Schedules.resolve_for(profile)
          |> Request.config(
            meeting_type,
            Request.limit_checker(request, moving_uid, start_date, end_date),
            duration_minutes || Request.default_duration_minutes()
          )
          |> Request.reach_until(request)

        busy = Request.busy_periods(events, user_id, start_date, end_date, moving)

        with {:ok, base_map} <-
               Calculate.range_availability(
                 start_date,
                 end_date,
                 Request.owner_timezone(profile),
                 request.user_timezone,
                 busy,
                 config
               ) do
          {:ok,
           GroupSlots.overlay_range(base_map, meeting_type, start_date, end_date, %{
             user_timezone: request.user_timezone,
             owner_timezone: Request.owner_timezone(profile),
             events: busy,
             config: config
           })}
        end
      end
    end)
  end
end
