defmodule Tymeslot.Availability.Offer.Request do
  @moduledoc false
  # What `Tymeslot.Availability.Offer` and `Tymeslot.Availability.Offer.Range`
  # both read from a booking page's request (`Offer.request()`): the
  # organiser's calendar and bookings as one busy set, the meeting being
  # moved, the booking-limit check, the engine config and the bounded
  # meeting length, and how found starts are labelled.

  alias Tymeslot.Availability.Bookability
  alias Tymeslot.Availability.{GroupSlots, Reach, Schedules, TimeSlots}
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Bookings.{Orchestrator, RescheduleSeat}
  alias Tymeslot.Demo
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.{RescheduleContext, SeatMoveContext}

  @default_duration_minutes 30

  # A day. The duration can come from a URL slug, which is visitor input, so an
  # unbounded parse would let `/:username/99999/book` hold a multi-day slot.
  defp max_duration_minutes, do: Reach.max_meeting_minutes()

  # How far outside the dates being rendered the booking fetch reaches. A
  # slot starting on the last rendered date can run for up to a day and keep
  # its buffer after it, and the window's own bounds are UTC while the days
  # are the booker's, up to a timezone offset away; nothing further out can
  # touch a slot inside.
  defp busy_window_padding_days, do: Reach.utc_padding_days()

  # The meeting length used when none is given.
  @spec default_duration_minutes() :: pos_integer()
  def default_duration_minutes, do: @default_duration_minutes

  # See `Tymeslot.Availability.Offer.config/4`.
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

  # Only a group type's times carry seat counts; everything else is the plain
  # labels the booking page has always read. Every start is listed under the
  # date it begins on, so a bare label plus the page's date is the instant.
  @spec offered_slots([DateTime.t()], map() | nil, Date.t(), map()) :: [term()]
  def offered_slots(starts, %MeetingTypeSchema{} = meeting_type, date, context) do
    if MeetingTypeSchema.group?(meeting_type),
      do: GroupSlots.enrich_day_slots(starts, meeting_type, date, context),
      else: labels(starts)
  end

  def offered_slots(starts, _meeting_type, _date, _context), do: labels(starts)

  defp labels(starts), do: Enum.map(starts, &TimeSlots.format_datetime_slot/1)

  # The provider fetch behind this is window-shaped, not month-shaped:
  # `Events.get_calendar_events/3` ignores the date it is given and always asks
  # for `today .. today + advance_booking_days`. Folding it under a key built
  # from the 42-day *display* range would therefore store the same event list
  # once per rendered month and guarantee a miss for anything that moves the
  # calendar, worst of all the next-available forward search, which re-enters
  # `Tymeslot.Availability.Offer.days_in_range/4` once per hop and would otherwise buy an identical round
  # trip to the host's calendar each time, on exactly the fully booked hosts
  # the search exists to help.
  #
  # So the events get their own entry, keyed on the user alone because that is
  # the fetch's entire input. The folded map keeps its display-range key: the
  # fold is what actually differs between hops. A date click reads the same
  # entry, so picking a day after the month view costs no provider round trip
  # either. Its slots can therefore be up to the cache's lifetime old; the
  # booking submit re-reads the calendars uncached
  # (`Tymeslot.Bookings.CalendarCheck`), and that read is what refuses a slot
  # taken in the meantime.
  #
  # Errors stay uncached, for the reason `get_or_compute_events/2` exists at
  # all: a timed-out calendar must be retried on the next request, not pinned
  # empty for the TTL. `Tymeslot.Availability.changed/1` drops this
  # entry with the folded maps, so a calendar sync cannot leave the two
  # disagreeing about how fresh they are.
  #
  # The events are cached with the bookability rule already applied
  # (`Tymeslot.Availability.Bookability`): an override and a calendar's
  # settings both call `changed/1`, which drops this entry.
  @spec booking_window_events(Offer.request(), Date.t()) :: {:ok, list()} | {:error, any()}
  def booking_window_events(%{profile: %{user_id: user_id}} = request, start_date) do
    AvailabilityCache.get_or_compute_events(
      AvailabilityCache.booking_window_events_key(user_id),
      fn ->
        with {:ok, events} <-
               CalendarEvents.get_calendar_events_from_context(
                 start_date,
                 user_id,
                 calendar_context(request)
               ) do
          {:ok, Bookability.apply_to_window(events, user_id)}
        end
      end
    )
  end

  # Everything that occupies the host's time across `first_date..last_date`:
  # their connected calendars, plus their own live bookings, which reach the
  # page this way rather than waiting to be mirrored onto a provider calendar
  # (see `Tymeslot.Meetings.BusyPeriods`). `moving` is then excluded from the
  # merged set, dropping the rescheduling meeting along with its mirror so that
  # a booking is never a conflict with itself.
  @spec busy_periods(list(), integer(), Date.t(), Date.t(), map() | nil) :: list()
  def busy_periods(events, user_id, first_date, last_date, moving) do
    events
    |> Meetings.merge_busy_periods(
      user_id,
      utc_day_start(Date.add(first_date, -busy_window_padding_days())),
      utc_day_start(Date.add(last_date, 1 + busy_window_padding_days()))
    )
    |> Meetings.reject_calendar_event_mirrors(moving)
  end

  defp utc_day_start(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  # Nil when the host has no booking limits configured, keeping the common path
  # free of extra queries. The dates are the booker's, so the counts cover
  # every host date a slot under them can fall on. The meeting being moved is
  # left out of the counts, exactly as the reschedule submit leaves it out.
  @spec limit_checker(Offer.request(), String.t() | nil, Date.t(), Date.t()) ::
          (DateTime.t() -> boolean()) | nil
  def limit_checker(
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
  @spec moving_meeting(Offer.request()) :: map() | nil
  def moving_meeting(%{reschedule_seat_token: token, profile: %{user_id: user_id}} = request)
      when is_binary(token) and is_integer(user_id) do
    case request[:seat_move] do
      %SeatMoveContext{token: ^token, seat: seat} -> RescheduleSeat.vacated_meeting(seat, user_id)
      _not_loaded -> RescheduleSeat.vacated_meeting(token, user_id)
    end
  end

  # The page's own load of the meeting, when it names the same meeting for
  # the same organiser; a fetch then needs no lookup of its own.
  def moving_meeting(%{
        reschedule_uid: uid,
        reschedule: %RescheduleContext{
          uid: uid,
          meeting: %{organizer_user_id: user_id} = meeting
        },
        profile: %{user_id: user_id}
      })
      when is_binary(uid) and is_integer(user_id),
      do: meeting

  def moving_meeting(%{reschedule_uid: uid, profile: %{user_id: user_id}})
      when is_binary(uid) and is_integer(user_id) do
    case Orchestrator.get_meeting_for_reschedule(uid, user_id) do
      {:ok, meeting} -> meeting
      {:error, _not_movable} -> nil
    end
  end

  def moving_meeting(_request), do: nil

  @spec moving_uid(map() | nil) :: String.t() | nil
  def moving_uid(nil), do: nil
  def moving_uid(%{uid: uid}), do: uid

  @spec demo?(Offer.request()) :: boolean()
  def demo?(%{profile: profile} = request) do
    Demo.demo_profile?(profile) || request[:demo_mode?] == true
  end

  # The context map the calendar fetch reads. Its contract names this one key
  # only, so the demo provider's extra keys stay out of it.
  @spec calendar_context(Offer.request()) :: map()
  def calendar_context(%{profile: profile}), do: %{organizer_profile: profile}

  # The context map the demo provider reads.
  @spec demo_context(Offer.request()) :: map()
  def demo_context(request) do
    request
    |> calendar_context()
    |> Map.merge(%{demo_mode: request[:demo_mode?] == true, meeting_type: request[:meeting_type]})
  end

  @spec owner_timezone(map() | nil) :: String.t()
  def owner_timezone(profile), do: Profiles.timezone(profile)

  @spec bounded_duration(term()) :: pos_integer()
  def bounded_duration(minutes) when is_integer(minutes) and minutes > 0,
    do: min(minutes, max_duration_minutes())

  def bounded_duration(slug) when is_binary(slug),
    do: slug |> TimeSlots.parse_duration() |> min(max_duration_minutes())

  def bounded_duration(_other), do: @default_duration_minutes
end
