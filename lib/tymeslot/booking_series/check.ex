defmodule Tymeslot.BookingSeries.Check do
  @moduledoc """
  Whether each session of a series can be booked, judged by the rules a
  single booking of it would meet (`Tymeslot.Bookings.Create`), so the
  sessions shown as available are the ones the booking accepts. Read-only:
  nothing is written or locked, and every write checks again.

  Each occurrence runs these checks in order and stops at its first failure:

    1. **Time.** The first occurrence must lie inside the booking window and
       outside the minimum notice (`Validation.validate_booking_time/2`). The
       later ones are checked for notice too, but not against the window;
       they must instead start within a year of the first.
    2. **Schedule.** The host's schedule must offer the time
       (`Calculate.offers_slot/6`); a type with fixed dates must have an
       offered time, or an open planned session, at that start.
    3. **Calendar.** The host's connected calendars, read once for the whole
       series (`CalendarCheck.enforce_many/3`).
    4. **Bookings.** No other live Tymeslot booking in the way, buffers
       included. A group session the booker can join is not in the way; one
       with too few seats is full.
    5. **Booking limits.** Counted as if the series' earlier available
       occurrences were already booked, so a weekly cap of two refuses a
       third session in one week. A seat in an existing group session adds
       no booking and is exempt, as it is for a single booking.

  A type with fixed-date sessions is judged as `Create` judges a booking of
  one: the session's own registration close stands in for the notice and the
  window, and the host's calendar, other bookings and booking limits play no
  part, because the session is the host's own plan.

  Whether the series is offered at all (`SeriesSettings.offered?/1`) is the
  caller's question, not this module's.
  """

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Bookings.CalendarCheck
  alias Tymeslot.Bookings.Validation
  alias Tymeslot.BookingSeries.Occurrence
  alias Tymeslot.BookingSeries.Plan
  alias Tymeslot.Clock
  alias Tymeslot.Meetings.BookingLimits
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.MeetingTypes.FixedDates
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles

  # Every occurrence after the first must start within this many days of it.
  @series_span_days 365

  @seconds_per_day 86_400

  @doc """
  Judges every occurrence of `plan`, in order.

  Returns `{:error, :availability_unverifiable}` when the host's calendars
  could not be read in full, which refuses every occurrence alike.

  Options:

    * `:now` - stands in for the clock.
    * `:booker_email` - lets a group session the booker already holds a
      seat in be reported as `:already_booked`; without it that check is
      skipped.
    * `:guests` - how many guests the booker brings to each session
      (default 0); each takes a seat.
  """
  @spec check(Plan.t(), keyword()) ::
          {:ok, [Occurrence.t()]} | {:error, :availability_unverifiable}
  def check(%Plan{} = plan, opts \\ []) do
    ctx = context(plan, opts)

    occurrences =
      plan.starts
      |> Enum.with_index(1)
      |> Enum.map(fn {start, position} -> occurrence(plan, start, position) end)

    sessions = Map.new(occurrences, &{&1.position, session(&1, ctx)})

    with {:ok, busy} <- calendar_busy(occurrences, sessions, ctx) do
      ctx =
        Map.merge(ctx, %{
          busy: busy,
          clashing: clashing(occurrences, sessions, ctx),
          first_start: hd(plan.starts)
        })

      {judged, _limits} =
        Enum.map_reduce(occurrences, limits_context(plan, ctx), fn occurrence, limits ->
          session = Map.fetch!(sessions, occurrence.position)

          occurrence
          |> Map.put(:seats_left, seats_left(session, ctx))
          |> judge(session, limits, ctx)
        end)

      {:ok, judged}
    end
  end

  defp context(%Plan{meeting_type: type} = plan, opts) do
    %{
      plan: plan,
      now: Keyword.get(opts, :now) || Clock.utc_now(),
      config: Schedules.booking_config(plan.organizer_user_id, type),
      group?: MeetingTypeSchema.group?(type),
      sessions_only?: FixedDates.sessions?(type),
      seats_requested: 1 + Keyword.get(opts, :guests, 0),
      booker_email: normalise_email(Keyword.get(opts, :booker_email))
    }
  end

  defp occurrence(plan, start, position) do
    %Occurrence{
      position: position,
      start: start,
      end: DateTime.add(start, plan.duration_minutes, :minute)
    }
  end

  defp judge(occurrence, session, limits, ctx) do
    with :ok <- check_time(occurrence, ctx),
         :ok <- check_schedule(occurrence, session, ctx),
         :ok <- check_calendar(occurrence, ctx),
         :ok <- check_bookings(occurrence, session, ctx),
         {:ok, limits} <- check_limits(occurrence, session, limits, ctx) do
      {occurrence, limits}
    else
      {:error, reason} -> {%{occurrence | status: {:unavailable, reason}}, limits}
    end
  end

  # 1. Time

  defp check_time(occurrence, %{sessions_only?: true} = ctx), do: check_span(occurrence, ctx)

  defp check_time(%Occurrence{position: 1, start: start}, ctx),
    do: start |> Validation.validate_booking_time(time_config(ctx)) |> time_result()

  # The window is the first occurrence's alone, so a later one is given a
  # window that just reaches it; the notice still applies.
  defp check_time(%Occurrence{start: start} = occurrence, ctx) do
    config = Map.put(time_config(ctx), :max_advance_booking_days, days_reaching(start, ctx.now))

    with :ok <- start |> Validation.validate_booking_time(config) |> time_result() do
      check_span(occurrence, ctx)
    end
  end

  defp time_config(ctx), do: Map.put(ctx.config, :current_time, ctx.now)

  defp time_result(:ok), do: :ok
  defp time_result({:error, :in_past}), do: {:error, :in_past}
  defp time_result({:error, {:too_soon, _hours}}), do: {:error, :too_soon}
  defp time_result({:error, {:too_far_ahead, _days}}), do: {:error, :too_far_ahead}

  defp check_span(%Occurrence{start: start}, %{first_start: first_start}) do
    if DateTime.compare(start, DateTime.add(first_start, @series_span_days, :day)) == :gt,
      do: {:error, :beyond_series_span},
      else: :ok
  end

  # 2. Schedule

  defp check_schedule(_occurrence, session, %{sessions_only?: true} = ctx) do
    case session do
      {_join_or_full, %MeetingSchema{planned: true} = planned} ->
        if PlannedSessions.open?(planned, ctx.now), do: :ok, else: {:error, :no_session}

      _no_planned_session ->
        {:error, :no_session}
    end
  end

  # `offers_slot/6` also applies the notice and the window against the real
  # clock; both were judged in step 1, so they are lifted here and the
  # answer is about the schedule alone.
  defp check_schedule(%Occurrence{start: start}, _session, %{plan: plan} = ctx) do
    config =
      Map.merge(ctx.config, %{
        min_advance_hours: 0,
        max_advance_booking_days: days_reaching(start, Clock.utc_now())
      })

    date = start |> DateTime.shift_zone!(plan.booker_tz) |> DateTime.to_date()

    case Calculate.offers_slot(
           date,
           start,
           plan.duration_minutes,
           plan.booker_tz,
           plan.host_tz,
           config
         ) do
      {:ok, true} -> :ok
      _not_offered -> {:error, not_offered_reason(plan.meeting_type)}
    end
  end

  defp not_offered_reason(meeting_type) do
    if FixedDates.offered_times?(meeting_type), do: :no_session, else: :outside_schedule
  end

  # 3. Calendar

  defp check_calendar(%Occurrence{start: start}, ctx) do
    if MapSet.member?(ctx.busy, start), do: {:error, :calendar_busy}, else: :ok
  end

  # One read for the whole series. A seat's own session is on the host's
  # calendar and is not a clash with joining it, as `Create` excludes it.
  defp calendar_busy(_occurrences, _sessions, %{sessions_only?: true}), do: {:ok, MapSet.new()}

  defp calendar_busy(occurrences, sessions, %{plan: plan, config: config}) do
    slots =
      Enum.map(occurrences, fn occurrence ->
        %{
          organizer_user_id: plan.organizer_user_id,
          start_datetime: occurrence.start,
          end_datetime: occurrence.end
        }
      end)

    joined = for {_position, {:join, meeting}} <- sessions, do: meeting

    case CalendarCheck.enforce_many(slots, config, exclude: joined) do
      {:ok, %{busy: busy}} -> {:ok, busy}
      {:error, _unverifiable} -> {:error, :availability_unverifiable}
    end
  end

  # 4. Bookings

  defp check_bookings(occurrence, {_join_or_full, meeting} = session, ctx) do
    cond do
      already_seated?(meeting, ctx.booker_email) -> {:error, :already_booked}
      match?({:full, _meeting}, session) -> {:error, :session_full}
      true -> check_clash(occurrence, ctx)
    end
  end

  defp check_bookings(occurrence, _new_slot, ctx), do: check_clash(occurrence, ctx)

  defp check_clash(%Occurrence{start: start}, ctx) do
    if MapSet.member?(ctx.clashing, start), do: {:error, :booked}, else: :ok
  end

  # Only an occurrence that would add a meeting can clash: a seat in an
  # existing session adds none, exactly as the seat transaction runs no
  # conflict count for a join.
  defp clashing(_occurrences, _sessions, %{sessions_only?: true}), do: MapSet.new()

  defp clashing(occurrences, sessions, %{plan: plan}) do
    slots =
      for occurrence <- occurrences, Map.fetch!(sessions, occurrence.position) in [nil, :none] do
        %{start_time: occurrence.start, end_time: occurrence.end}
      end

    Scheduling.clashing_starts(plan.organizer_user_id, plan.meeting_type.id, slots)
  end

  defp already_seated?(_meeting, nil), do: false

  defp already_seated?(%MeetingSchema{id: meeting_id}, email) do
    meeting_id
    |> ParticipantQueries.list_live_for_meeting()
    |> Enum.any?(&(normalise_email(&1.email) == email))
  end

  # 5. Booking limits

  defp check_limits(_occurrence, _session, limits, %{sessions_only?: true}), do: {:ok, limits}
  defp check_limits(_occurrence, {:join, _meeting}, limits, _ctx), do: {:ok, limits}
  defp check_limits(_occurrence, _session, nil, _ctx), do: {:ok, nil}

  defp check_limits(%Occurrence{start: start}, _session, limits, %{plan: plan}) do
    if BookingLimits.slot_blocked?(limits, start) do
      {:error, :limit_reached}
    else
      {:ok,
       BookingLimits.count_booking(limits, %{
         start_time: start,
         meeting_type_id: plan.meeting_type.id
       })}
    end
  end

  # Nil when the host has no limits configured (and nothing was queried).
  defp limits_context(_plan, %{sessions_only?: true}), do: nil

  defp limits_context(%Plan{} = plan, _ctx) do
    host_day = &BookingLimits.day_key(&1, plan.host_tz)

    Checker.load_context(
      plan.organizer_user_id,
      Profiles.get_profile_settings(plan.organizer_user_id),
      plan.meeting_type,
      host_day.(hd(plan.starts)),
      host_day.(List.last(plan.starts))
    )
  end

  # Group sessions

  # The live session each occurrence would join, be refused by, or create
  # (`GroupScheduling.session_at/3`); nil for a one-to-one type.
  defp session(_occurrence, %{group?: false}), do: nil

  defp session(%Occurrence{start: start}, %{plan: plan} = ctx),
    do: GroupScheduling.session_at(plan.meeting_type.id, start, ctx.seats_requested)

  defp seats_left(nil, _ctx), do: nil
  defp seats_left(:none, %{plan: plan}), do: plan.meeting_type.max_participants

  defp seats_left({_join_or_full, meeting}, _ctx) do
    if MeetingSchema.group?(meeting), do: Seats.seats_left(meeting, meeting.capacity), else: 0
  end

  # Helpers

  # A booking window just long enough to reach `start` from `now`.
  defp days_reaching(start, now), do: max(div(DateTime.diff(start, now), @seconds_per_day) + 1, 1)

  defp normalise_email(nil), do: nil
  defp normalise_email(email), do: email |> String.trim() |> String.downcase()
end
