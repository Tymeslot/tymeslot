defmodule Tymeslot.Availability.Offer do
  @moduledoc """
  The times a public booking page offers.

  Answers the two questions the booking page asks: which times are free on one
  date (`slots_for_date/3`), and which days in a range have any free time at
  all (`days_in_range/4`). Both build their rules from `config/4`, which rests
  on `Tymeslot.Availability.Schedules.config/2`, the same rules the booking
  submit re-checks against (`Tymeslot.Bookings.Policy.scheduling_config/2`).
  A time offered here is therefore a time the submit accepts.

  Works on a plain request map rather than a socket, so a fetch task can
  capture it whole and nothing here depends on the web layer.
  """

  alias Tymeslot.Availability.{Calculate, Schedules, TimeSlots}
  alias Tymeslot.Demo
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.Profiles

  # A day. The duration can come from a URL slug, which is visitor input, so an
  # unbounded parse would let `/:username/99999/book` hold a multi-day slot.
  @max_duration_minutes 1440
  @default_duration_minutes 30

  @typedoc """
  What a booking page is showing, and to whom.

    * `:profile` - the organiser's profile. Its `user_id` is whose calendar and
      bookings are read, so the organiser cannot be named separately from the
      profile and the two cannot disagree.
    * `:user_timezone` - the booker's timezone.
    * `:meeting_type` - the resolved meeting type, or nil before one is chosen.
    * `:demo_mode?` - whether the page is running as a demo.
    * `:debug_calendar_module` - a calendar module override, for development.
  """
  @type request :: %{
          required(:profile) => %{required(:user_id) => integer(), optional(atom()) => any()},
          required(:user_timezone) => String.t(),
          optional(:meeting_type) => map() | nil,
          optional(:demo_mode?) => boolean() | nil,
          optional(:debug_calendar_module) => module() | nil
        }

  @doc """
  The times free on `date_string` (ISO 8601) for a meeting of `duration`.

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
    with {:ok, events} <-
           CalendarEvents.get_calendar_events_from_context(date, user_id, context(request)) do
      duration_minutes = bounded_duration(duration)
      meeting_type = request[:meeting_type]

      config =
        meeting_type
        |> Schedules.resolve_for(profile)
        |> config(meeting_type, limit_checker(request, date, date), duration_minutes)

      Calculate.available_slots(
        date,
        duration_minutes,
        request.user_timezone,
        owner_timezone(profile),
        events,
        config
      )
    end
  end

  defp free_days(
         %{profile: %{user_id: user_id} = profile} = request,
         start_date,
         end_date,
         duration_minutes
       ) do
    meeting_type = request[:meeting_type]

    cache_key =
      AvailabilityCache.availability_range_key(
        user_id,
        start_date,
        end_date,
        request.user_timezone,
        duration_minutes,
        meeting_type && meeting_type.id
      )

    AvailabilityCache.get_or_compute_events(cache_key, fn ->
      with {:ok, events} <- booking_window_events(request, start_date) do
        config =
          meeting_type
          |> Schedules.resolve_for(profile)
          |> config(
            meeting_type,
            limit_checker(request, start_date, end_date),
            duration_minutes || @default_duration_minutes
          )

        Calculate.range_availability(
          start_date,
          end_date,
          owner_timezone(profile),
          request.user_timezone,
          events,
          config
        )
      end
    end)
  end

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
        CalendarEvents.get_calendar_events_from_context(start_date, user_id, context(request))
      end
    )
  end

  # Nil when the host has no booking limits configured, keeping the common path
  # free of extra queries.
  defp limit_checker(%{profile: %{user_id: user_id} = profile} = request, start_date, end_date) do
    Checker.build_slot_checker(user_id, profile, request[:meeting_type], start_date, end_date)
  end

  defp demo?(%{profile: profile} = request) do
    Demo.demo_profile?(profile) || request[:demo_mode?] == true
  end

  # The context map the calendar fetch and the demo provider read.
  defp context(%{profile: profile} = request) do
    %{
      demo_mode: request[:demo_mode?] == true,
      organizer_profile: profile,
      meeting_type: request[:meeting_type],
      debug_calendar_module: request[:debug_calendar_module]
    }
  end

  defp owner_timezone(profile), do: profile.timezone || Profiles.get_default_timezone()

  defp bounded_duration(minutes) when is_integer(minutes) and minutes > 0,
    do: min(minutes, @max_duration_minutes)

  defp bounded_duration(slug) when is_binary(slug),
    do: slug |> TimeSlots.parse_duration() |> min(@max_duration_minutes)

  defp bounded_duration(_other), do: @default_duration_minutes
end
