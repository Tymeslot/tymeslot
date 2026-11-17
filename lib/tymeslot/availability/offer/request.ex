defmodule Tymeslot.Availability.Offer.Request do
  @moduledoc false
  # What `Tymeslot.Availability.Offer` and `Tymeslot.Availability.Offer.Range`
  # both read from a booking page's request (`Offer.request()`): the
  # organiser's calendar events (read by `Offer.HostCalendar`) and bookings
  # as one busy set, the meeting being moved, the booking-limit check, the
  # engine config and the bounded meeting length, and how found starts are
  # labelled.

  alias Tymeslot.Availability.{GroupSlots, Reach, Schedules, TimeSlots}
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Availability.Offer.HostCalendar
  alias Tymeslot.BookingSeries
  alias Tymeslot.Demo
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.Meetings.ExternalCalendar
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles

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

  # Everything that occupies the host's time across `first_date..last_date`:
  # their connected calendars, plus their own live bookings, which reach the
  # page this way rather than waiting to be mirrored onto a provider calendar
  # (see `Tymeslot.Meetings.BusyPeriods`). `moving` is then excluded from the
  # merged set, dropping the rescheduling meeting along with its mirror so that
  # a booking is never a conflict with itself.
  @spec busy_periods(list(), integer(), Date.t(), Date.t(), map() | nil) :: list()
  def busy_periods(events, user_id, first_date, last_date, moving) do
    events
    |> ExternalCalendar.merge_busy_periods(
      user_id,
      utc_day_start(Date.add(first_date, -busy_window_padding_days())),
      utc_day_start(Date.add(last_date, 1 + busy_window_padding_days()))
    )
    |> ExternalCalendar.reject_calendar_event_mirrors(moving)
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

  # A booking window just long enough to reach the request's `:window_until`
  # from today, as `BookingSeries.Check` gives a series' later sessions;
  # never shorter than the schedule's own.
  @spec reach_until(map(), Offer.request()) :: map()
  def reach_until(config, %{window_until: %Date{} = until}),
    do: BookingSeries.reach_until(config, until)

  def reach_until(config, _request), do: config

  @spec demo?(Offer.request()) :: boolean()
  def demo?(%{profile: profile} = request) do
    Demo.demo_profile?(profile) || request[:demo_mode?] == true
  end

  # The context map the demo provider reads.
  @spec demo_context(Offer.request()) :: map()
  def demo_context(request) do
    request
    |> HostCalendar.context()
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
