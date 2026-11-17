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
    3. **Calendar.** The host's connected calendars, read once for the
       occurrences that passed steps 1 and 2 (`CalendarCheck.enforce_many/3`).
    4. **Bookings.** No other live Tymeslot booking in the way, buffers
       included. A group session the booker can join is not in the way; one
       with too few seats is full. An earlier available occurrence of the
       same series is in the way too (`:overlaps_session`), since the series
       is booked as one.
    5. **Booking limits.** Counted as if the series' earlier available
       occurrences were already booked, so a weekly cap of two refuses a
       third session in one week. A seat in an existing group session adds
       no booking and is exempt, as it is for a single booking.

  The whole series is read in a fixed number of queries, however many
  occurrences it has: the schedule, the group sessions and their seats, the
  booking limits and the conflicting meetings are each read once.

  A type with fixed-date sessions is judged as `Create` judges a booking of
  one: the session's own registration close stands in for the notice and the
  window, and the host's calendar, other bookings and booking limits play no
  part, because the session is the host's own plan.

  Whether the series is offered at all (`SeriesSettings.offered?/1`) is the
  caller's question, not this module's.
  """

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.Reach
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
  alias Tymeslot.MeetingTypes.FixedDates
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.TimeRange

  # Every occurrence after the first must start within this many days of it.
  @series_span_days 365

  @seconds_per_day 86_400

  @doc "How many days after the first session every later one must start within."
  @spec span_days() :: pos_integer()
  def span_days, do: @series_span_days

  @doc """
  Judges every occurrence of `plan`, in order.

  Returns `{:error, :availability_unverifiable}` when the host's calendars
  or schedule could not be read in full, which refuses every occurrence
  alike.

  Options:

    * `:now` - stands in for the clock in the time checks (step 1) and for
      a planned session's registration close. The schedule check
      (`Calculate.offers_slot/6`) still drops a start already past by the
      real clock.
    * `:booker_email` - lets a group session the booker already holds a
      seat in be reported as `:already_booked`; without it that check is
      skipped.
    * `:guests` - how many guests the booker brings to each session
      (default 0); each takes a seat.
    * `:strict_calendar` - `true` refuses the series with
      `:availability_unverifiable` when the host's calendars could not be
      reached at all, rather than reading them as free
      (`CalendarCheck.enforce_many/3`). Booking a series sets it; a preview
      does not.
  """
  @spec check(Plan.t(), keyword()) ::
          {:ok, [Occurrence.t()]} | {:error, :availability_unverifiable}
  def check(%Plan{} = plan, opts \\ []) do
    occurrences =
      plan.starts
      |> Enum.with_index(1)
      |> Enum.map(fn {start, position} -> occurrence(plan, start, position) end)

    ctx = context(plan, opts)

    with {:ok, screened} <- screen(occurrences, ctx),
         passing = for({occurrence, :ok} <- screened, do: occurrence),
         {:ok, busy} <- calendar_busy(passing, ctx) do
      ctx = Map.merge(ctx, %{busy: busy, clashing: clashing(passing, ctx)})

      {judged, _state} =
        Enum.map_reduce(screened, {limits_context(plan, ctx), []}, &judge(&1, &2, ctx))

      {:ok, judged}
    end
  end

  defp context(%Plan{meeting_type: type} = plan, opts) do
    now = Keyword.get(opts, :now) || Clock.utc_now()
    group? = MeetingTypeSchema.group?(type)
    sessions = sessions(plan, group?, 1 + Keyword.get(opts, :guests, 0))

    %{
      plan: plan,
      now: now,
      config: prefetched_config(plan),
      sessions_only?: FixedDates.sessions?(type),
      sessions: sessions,
      seated: seated(sessions, Keyword.get(opts, :booker_email)),
      first_start: hd(plan.starts),
      strict_calendar: Keyword.get(opts, :strict_calendar, false)
    }
  end

  # The schedule, overrides and time off, read once for every booker date
  # the series touches and the host dates each can reach, so the schedule
  # check reads them from memory.
  defp prefetched_config(%Plan{config: config, starts: starts, booker_tz: booker_tz}) do
    dates = Enum.map(starts, &(&1 |> DateTime.shift_zone!(booker_tz) |> DateTime.to_date()))

    Calculate.prefetch_schedule_data(
      config,
      config.schedule_id,
      dates |> Enum.min(Date) |> Date.add(-Reach.owner_days()),
      dates |> Enum.max(Date) |> Date.add(Reach.owner_days())
    )
  end

  defp occurrence(plan, start, position) do
    %Occurrence{
      position: position,
      start: start,
      end: DateTime.add(start, plan.duration_minutes, :minute)
    }
  end

  # Steps 1 and 2, which need nothing read per occurrence. A schedule that
  # cannot be read refuses the whole series, as `ScheduleCheck` refuses a
  # single booking.
  defp screen(occurrences, ctx) do
    screened =
      Enum.reduce_while(occurrences, [], fn occurrence, screened ->
        case with(:ok <- check_time(occurrence, ctx), do: check_schedule(occurrence, ctx)) do
          :unverifiable -> {:halt, :unverifiable}
          result -> {:cont, [{occurrence, result} | screened]}
        end
      end)

    case screened do
      :unverifiable -> {:error, :availability_unverifiable}
      screened -> {:ok, Enum.reverse(screened)}
    end
  end

  defp judge({occurrence, screened}, {limits, accepted}, ctx) do
    session = session(occurrence, ctx)
    occurrence = %{occurrence | seats_left: seats_left(session, ctx)}

    with :ok <- screened,
         :ok <- check_calendar(occurrence, ctx),
         :ok <- check_bookings(occurrence, session, ctx),
         :ok <- check_series_overlap(occurrence, session, accepted, ctx),
         {:ok, limits} <- check_limits(occurrence, session, limits, ctx) do
      {occurrence, {limits, accept(accepted, occurrence, session, ctx)}}
    else
      {:error, :no_session} ->
        {%{occurrence | status: {:unavailable, :no_session}, seats_left: nil}, {limits, accepted}}

      {:error, reason} ->
        {%{occurrence | status: {:unavailable, reason}}, {limits, accepted}}
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

  defp check_schedule(occurrence, %{sessions_only?: true} = ctx) do
    case session(occurrence, ctx) do
      {_join_or_full, %MeetingSchema{planned: true} = planned, _seats_left} ->
        if PlannedSessions.open?(planned, ctx.now), do: :ok, else: {:error, :no_session}

      _no_planned_session ->
        {:error, :no_session}
    end
  end

  # `offers_slot/6` also applies the notice and the window against the real
  # clock; both were judged in step 1, so they are lifted here and the
  # answer is about the schedule alone.
  defp check_schedule(%Occurrence{start: start}, %{plan: plan} = ctx) do
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
      {:ok, false} -> {:error, not_offered_reason(plan.meeting_type)}
      {:error, _reason} -> :unverifiable
    end
  end

  defp not_offered_reason(meeting_type) do
    if FixedDates.offered_times?(meeting_type), do: :no_session, else: :outside_schedule
  end

  # 3. Calendar

  defp check_calendar(%Occurrence{start: start}, ctx) do
    if MapSet.member?(ctx.busy, start), do: {:error, :calendar_busy}, else: :ok
  end

  # One read for every occurrence still standing. A seat's own session is
  # on the host's calendar and is not a clash with joining it, as `Create`
  # excludes it.
  defp calendar_busy(_passing, %{sessions_only?: true}), do: {:ok, MapSet.new()}

  defp calendar_busy(passing, %{plan: plan, config: config} = ctx) do
    slots =
      Enum.map(passing, fn occurrence ->
        %{
          organizer_user_id: plan.organizer_user_id,
          start_datetime: occurrence.start,
          end_datetime: occurrence.end
        }
      end)

    joined =
      for occurrence <- passing,
          {:join, meeting, _left} <- [session(occurrence, ctx)],
          do: meeting

    case CalendarCheck.enforce_many(slots, config,
           exclude: joined,
           strict_calendar: ctx.strict_calendar
         ) do
      {:ok, %{busy: busy}} -> {:ok, busy}
      {:error, _unverifiable} -> {:error, :availability_unverifiable}
    end
  end

  # 4. Bookings

  defp check_bookings(occurrence, {state, meeting, _seats_left}, ctx) do
    cond do
      MapSet.member?(ctx.seated, meeting.id) -> {:error, :already_booked}
      state == :full -> {:error, :session_full}
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
  defp clashing(_passing, %{sessions_only?: true}), do: MapSet.new()

  defp clashing(passing, %{plan: plan} = ctx) do
    slots =
      for occurrence <- passing, adds_meeting?(session(occurrence, ctx)) do
        %{start_time: occurrence.start, end_time: occurrence.end}
      end

    Scheduling.clashing_starts(plan.organizer_user_id, plan.meeting_type.id, slots)
  end

  # The series' own earlier sessions are booked with it, so each is in the
  # way of the later ones exactly as an existing booking of the type would
  # be: buffers on both sides.
  defp check_series_overlap(_occurrence, _session, [], _ctx), do: :ok

  defp check_series_overlap(occurrence, session, accepted, ctx) do
    if adds_meeting?(session) and
         TimeRange.has_conflict_with_events?(
           occurrence.start,
           occurrence.end,
           accepted,
           Calculate.config_buffers(ctx.config)
         ),
       do: {:error, :overlaps_session},
       else: :ok
  end

  defp accept(accepted, occurrence, session, ctx) do
    if adds_meeting?(session) and not ctx.sessions_only?,
      do: [
        %{
          start_time: occurrence.start,
          end_time: occurrence.end,
          buffers: Calculate.config_buffers(ctx.config)
        }
        | accepted
      ],
      else: accepted
  end

  # 5. Booking limits

  defp check_limits(_occurrence, _session, limits, %{sessions_only?: true}), do: {:ok, limits}
  defp check_limits(_occurrence, {:join, _meeting, _left}, limits, _ctx), do: {:ok, limits}
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

  # The live session each start would join, be refused by, or create
  # (`GroupScheduling.sessions_at/3`), read for every start at once; nil
  # for a one-to-one type.
  defp sessions(_plan, false, _seats_requested), do: nil

  defp sessions(plan, true, seats_requested),
    do: GroupScheduling.sessions_at(plan.meeting_type.id, plan.starts, seats_requested)

  defp session(_occurrence, %{sessions: nil}), do: nil
  defp session(%Occurrence{start: start}, %{sessions: sessions}), do: Map.fetch!(sessions, start)

  # The sessions among them the booker already holds a seat in, in one read.
  defp seated(sessions, email) when is_map(sessions) and is_binary(email) do
    meeting_ids = for {_start, {_state, meeting, _left}} <- sessions, do: meeting.id
    ParticipantQueries.meeting_ids_seating(String.trim(email), meeting_ids)
  end

  defp seated(_sessions, _email), do: MapSet.new()

  defp adds_meeting?(session), do: session in [nil, :none]

  defp seats_left(nil, _ctx), do: nil
  defp seats_left({_join_or_full, _meeting, seats_left}, _ctx), do: seats_left
  defp seats_left(:none, %{sessions_only?: true}), do: nil
  defp seats_left(:none, %{plan: plan}), do: plan.meeting_type.max_participants

  # A booking window just long enough to reach `start` from `now`.
  defp days_reaching(start, now), do: max(div(DateTime.diff(start, now), @seconds_per_day) + 1, 1)
end
