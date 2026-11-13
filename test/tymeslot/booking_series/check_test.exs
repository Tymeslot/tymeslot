defmodule Tymeslot.BookingSeries.CheckTest do
  @moduledoc """
  A series is judged occurrence by occurrence against the rules a single
  booking of each would meet: the booking window (first occurrence only),
  the series span, the schedule, the host's calendar (read once), other
  bookings, group seats and booking limits counted across the series itself.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Check
  alias Tymeslot.BookingSeries.Occurrence
  alias Tymeslot.BookingSeries.Plan
  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup do
    test_pid = self()

    stub(CalendarMock, :get_events_for_range_fresh, fn user_id, start_date, end_date ->
      send(test_pid, {:fetched, user_id, start_date, end_date})
      {:ok, []}
    end)

    host = create_always_bookable_profile(timezone: "Etc/UTC")
    now = DateTime.utc_now(:second)
    %{host: host, now: now, today: DateTime.to_date(now)}
  end

  defp series_type(host, attrs \\ []) do
    insert(
      :meeting_type,
      Keyword.merge(
        [
          user: host.user,
          duration_minutes: 30,
          series_mode: :recurring,
          series_frequency: :weekly,
          series_interval: 1,
          series_min_occurrences: 2,
          series_max_occurrences: 26
        ],
        attrs
      )
    )
  end

  # 10:00 UTC, `days` from `today`.
  defp at(today, days), do: today |> Date.add(days) |> DateTime.new!(~T[10:00:00], "Etc/UTC")

  # The first Monday at least `days` from `today`, at 10:00 UTC.
  defp monday_at_least(today, days) do
    date = Date.add(today, days)

    date
    |> Date.add(Integer.mod(1 - Date.day_of_week(date), 7))
    |> DateTime.new!(~T[10:00:00], "Etc/UTC")
  end

  defp statuses(occurrences), do: Enum.map(occurrences, & &1.status)

  defp set_window(host, days) do
    host.schedule |> Changeset.change(advance_booking_days: days) |> Repo.update!()
  end

  test "all occurrences available", %{host: host, now: now, today: today} do
    type = series_type(host)

    assert {:ok, occurrences} = BookingSeries.preview(type, at(today, 7), count: 4, now: now)

    assert Enum.map(occurrences, & &1.start) == [
             at(today, 7),
             at(today, 14),
             at(today, 21),
             at(today, 28)
           ]

    assert Enum.map(occurrences, & &1.position) == [1, 2, 3, 4]
    assert Enum.all?(occurrences, &Occurrence.available?/1)
    assert hd(occurrences).end == DateTime.add(at(today, 7), 30, :minute)
    assert Enum.all?(occurrences, &is_nil(&1.seats_left))
  end

  test "the booking window applies only to the first occurrence", %{
    host: host,
    now: now,
    today: today
  } do
    set_window(host, 30)
    type = series_type(host)

    assert {:ok, occurrences} = BookingSeries.preview(type, at(today, 7), count: 8, now: now)
    assert statuses(occurrences) == List.duplicate(:available, 8)

    assert {:ok, [first | rest]} = BookingSeries.preview(type, at(today, 31), count: 3, now: now)
    assert first.status == {:unavailable, :too_far_ahead}
    assert statuses(rest) == [:available, :available]
  end

  test "an occurrence in the minimum notice is too soon", %{host: host, today: today} do
    type = series_type(host, series_mode: :flexible)
    now = DateTime.add(at(today, 7), -1, :hour)

    assert {:ok, occurrences} =
             BookingSeries.preview(type, [at(today, 7), at(today, 8)], now: now)

    assert statuses(occurrences) == [{:unavailable, :too_soon}, :available]
  end

  test "an occurrence past 365 days is beyond the span", %{host: host, now: now, today: today} do
    type = series_type(host, series_mode: :flexible)

    assert {:ok, occurrences} =
             BookingSeries.preview(type, [at(today, 7), at(today, 7 + 365), at(today, 7 + 366)],
               now: now
             )

    assert statuses(occurrences) == [:available, :available, {:unavailable, :beyond_series_span}]
  end

  test "time off makes one occurrence unavailable", %{host: host, now: now, today: today} do
    day = Date.add(today, 14)
    insert(:time_off_period, profile: host.profile, starts_on: day, ends_on: day)
    type = series_type(host)

    assert {:ok, occurrences} = BookingSeries.preview(type, at(today, 7), count: 3, now: now)
    assert statuses(occurrences) == [:available, {:unavailable, :outside_schedule}, :available]
  end

  test "an existing booking clashes", %{host: host, now: now, today: today} do
    insert(:meeting,
      organizer_user_id: host.user.id,
      start_time: at(today, 21),
      end_time: DateTime.add(at(today, 21), 30, :minute),
      status: :confirmed
    )

    type = series_type(host)

    assert {:ok, occurrences} = BookingSeries.preview(type, at(today, 7), count: 3, now: now)
    assert statuses(occurrences) == [:available, :available, {:unavailable, :booked}]
  end

  test "a calendar event clashes", %{host: host, now: now, today: today} do
    test_pid = self()
    busy_start = DateTime.add(at(today, 14), 10, :minute)

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, start_date, end_date ->
      send(test_pid, {:fetched, start_date, end_date})

      {:ok,
       [%{uid: "dentist", start_time: busy_start, end_time: DateTime.add(busy_start, 1, :hour)}]}
    end)

    type = series_type(host)

    assert {:ok, occurrences} = BookingSeries.preview(type, at(today, 7), count: 3, now: now)
    assert statuses(occurrences) == [:available, {:unavailable, :calendar_busy}, :available]

    assert_received {:fetched, start_date, end_date}
    assert Date.compare(start_date, DateTime.to_date(at(today, 7))) == :lt
    assert Date.compare(end_date, DateTime.to_date(at(today, 21))) == :gt
    refute_received {:fetched, _start_date, _end_date}
  end

  test "an unreadable calendar refuses the whole series", %{host: host, now: now, today: today} do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:error, :some_calendars_unavailable}
    end)

    type = series_type(host)

    assert {:error, :availability_unverifiable} =
             BookingSeries.preview(type, at(today, 7), count: 3, now: now)
  end

  test "a weekly cap counts the series' own occurrences", %{now: now, today: today} do
    host =
      create_always_bookable_profile(timezone: "Etc/UTC", profile: %{max_bookings_per_week: 1})

    type = series_type(host, series_frequency: :daily)

    assert {:ok, occurrences} =
             BookingSeries.preview(type, monday_at_least(today, 7), count: 3, now: now)

    assert statuses(occurrences) == [
             :available,
             {:unavailable, :limit_reached},
             {:unavailable, :limit_reached}
           ]
  end

  test "an occurrence refused for another reason does not count towards a cap", %{
    now: now,
    today: today
  } do
    host =
      create_always_bookable_profile(timezone: "Etc/UTC", profile: %{max_bookings_per_week: 2})

    type = series_type(host, series_frequency: :daily)
    monday = monday_at_least(today, 7)

    insert(:meeting,
      organizer_user_id: host.user.id,
      start_time: DateTime.add(monday, 15, :minute),
      end_time: DateTime.add(monday, 45, :minute),
      status: :confirmed
    )

    # The clashing booking takes one of the week's two; the refused first
    # occurrence takes none, so the second still fits and the third does not.
    assert {:ok, occurrences} = BookingSeries.preview(type, monday, count: 3, now: now)

    assert statuses(occurrences) == [
             {:unavailable, :booked},
             :available,
             {:unavailable, :limit_reached}
           ]
  end

  describe "a group type" do
    setup %{host: host} do
      %{type: series_type(host, max_participants: 2)}
    end

    defp session!(host, type, start, seats_taken) do
      meeting =
        insert(:group_meeting,
          organizer_user_id: host.user.id,
          meeting_type_id: type.id,
          start_time: start,
          end_time: DateTime.add(start, 30, :minute),
          capacity: 2
        )

      for email <- Enum.take(["ann@example.com", "bob@example.com"], seats_taken) do
        insert(:participant, meeting: meeting, email: email)
      end

      meeting
    end

    test "a full group session is reported", %{host: host, type: type, now: now, today: today} do
      session!(host, type, at(today, 14), 2)

      assert {:ok, [first, second, third]} =
               BookingSeries.preview(type, at(today, 7), count: 3, now: now)

      assert second.status == {:unavailable, :session_full}
      assert second.seats_left == 0
      assert first.status == :available and first.seats_left == 2
      assert third.status == :available
    end

    test "a session with a seat left is joined, not a clash", %{
      host: host,
      type: type,
      now: now,
      today: today
    } do
      session!(host, type, at(today, 14), 1)

      assert {:ok, occurrences} = BookingSeries.preview(type, at(today, 7), count: 3, now: now)
      assert statuses(occurrences) == [:available, :available, :available]
      assert Enum.at(occurrences, 1).seats_left == 1
    end

    test "a seat in an existing session is exempt from the booking limits",
         %{host: host, now: now, today: today} do
      host.profile |> Changeset.change(max_bookings_per_week: 1) |> Repo.update!()
      type = series_type(host, max_participants: 2)
      # The session already fills the cap of its week; joining it adds no
      # booking.
      session!(host, type, at(today, 14), 1)

      assert {:ok, occurrences} = BookingSeries.preview(type, at(today, 7), count: 2, now: now)
      assert statuses(occurrences) == [:available, :available]
    end

    test "guests need seats too", %{host: host, type: type, now: now, today: today} do
      session!(host, type, at(today, 14), 1)

      assert {:ok, occurrences} =
               BookingSeries.preview(type, at(today, 7), count: 2, now: now, guests: 1)

      assert statuses(occurrences) == [:available, {:unavailable, :session_full}]
    end

    test "a session the booker already holds a seat in", %{
      host: host,
      type: type,
      now: now,
      today: today
    } do
      session!(host, type, at(today, 14), 1)

      assert {:ok, occurrences} =
               BookingSeries.preview(type, at(today, 7),
                 count: 2,
                 now: now,
                 booker_email: "Ann@Example.com"
               )

      assert statuses(occurrences) == [:available, {:unavailable, :already_booked}]
    end
  end

  test "a fixed-date type needs a planned session at each start", %{now: now, today: today} do
    user = insert(:user)
    insert(:profile, user: user, timezone: "Etc/UTC")

    type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 60,
        max_participants: 3,
        fixed_dates: true,
        series_mode: :flexible,
        series_min_occurrences: 2,
        series_max_occurrences: 4
      )

    for start <- [at(today, 7), at(today, 14)] do
      insert(:group_meeting,
        organizer_user_id: user.id,
        meeting_type_id: type.id,
        planned: true,
        start_time: start,
        end_time: DateTime.add(start, 60, :minute),
        capacity: 3
      )
    end

    assert {:ok, occurrences} =
             BookingSeries.preview(type, [at(today, 7), at(today, 14), at(today, 21)], now: now)

    assert statuses(occurrences) == [:available, :available, {:unavailable, :no_session}]
    assert Enum.map(occurrences, & &1.seats_left) == [3, 3, nil]
    refute_received {:fetched, _user_id, _start_date, _end_date}
  end

  test "a session count outside the type's range is refused", %{
    host: host,
    now: now,
    today: today
  } do
    type = series_type(host, series_max_occurrences: 4)

    assert {:error, :invalid_count} =
             BookingSeries.preview(type, at(today, 7), count: 5, now: now)

    assert {:error, :invalid_count} =
             BookingSeries.preview(type, at(today, 7), count: 1, now: now)
  end

  test "overlapping picks are refused", %{host: host, now: now, today: today} do
    type = series_type(host, series_mode: :flexible)

    assert {:error, :overlapping_starts} =
             BookingSeries.preview(type, [at(today, 7), at(today, 7)], now: now)

    assert {:error, :overlapping_starts} =
             BookingSeries.preview(
               type,
               [at(today, 8), DateTime.add(at(today, 7), 29, :minute), at(today, 7)],
               now: now
             )

    assert {:ok, _back_to_back} =
             BookingSeries.preview(type, [at(today, 7), DateTime.add(at(today, 7), 30, :minute)],
               now: now
             )
  end

  test "an earlier session of the series is in the way of a later one, buffers included",
       %{host: host, now: now, today: today} do
    # The schedule keeps 15 minutes either side, so back-to-back sessions
    # cannot both be booked.
    type = series_type(host, series_mode: :flexible)
    second = DateTime.add(at(today, 7), 30, :minute)

    assert {:ok, occurrences} =
             BookingSeries.preview(type, [at(today, 7), second, at(today, 8)], now: now)

    assert statuses(occurrences) == [:available, {:unavailable, :overlaps_session}, :available]
  end

  test "an occurrence already past is in the past", %{host: host, today: today} do
    type = series_type(host, series_mode: :flexible)
    now = DateTime.add(at(today, 7), 1, :hour)

    assert {:ok, occurrences} =
             BookingSeries.preview(type, [at(today, 7), at(today, 8)], now: now)

    assert statuses(occurrences) == [{:unavailable, :in_past}, :available]
  end

  test "a weekly cap counts by the host's week, not UTC's", %{now: now, today: today} do
    host =
      create_always_bookable_profile(
        timezone: "Pacific/Auckland",
        profile: %{max_bookings_per_week: 1}
      )

    week_start = Management.get_week_start(host.user.id)

    # The first day of a host week, at 09:00 in Auckland: the evening before
    # in UTC, so the two sessions fall in one Auckland week but in two UTC
    # weeks.
    first_day =
      today
      |> Date.add(7)
      |> Stream.iterate(&Date.add(&1, 1))
      |> Enum.find(&(Date.beginning_of_week(&1, week_start) == &1))

    first =
      first_day
      |> DateTime.new!(~T[09:00:00], "Pacific/Auckland")
      |> DateTime.shift_zone!("Etc/UTC")

    type = series_type(host, series_frequency: :daily)

    assert {:ok, occurrences} = BookingSeries.preview(type, first, count: 2, now: now)

    assert Date.beginning_of_week(DateTime.to_date(first), week_start) !=
             Date.beginning_of_week(DateTime.to_date(Enum.at(occurrences, 1).start), week_start)

    assert statuses(occurrences) == [:available, {:unavailable, :limit_reached}]
  end

  test "a check reads the database a fixed number of times, however long the series",
       %{host: host, now: now, today: today} do
    type = series_type(host, series_frequency: :daily, series_max_occurrences: 20)

    {:ok, ten} = Plan.recurring(type, at(today, 7), 10)
    {:ok, twenty} = Plan.recurring(type, at(today, 7), 20)

    assert queries_during(fn -> Check.check(ten, now: now) end) ==
             queries_during(fn -> Check.check(twenty, now: now) end)
  end

  test "a group type's check reads the database a fixed number of times",
       %{host: host, now: now, today: today} do
    type = series_type(host, max_participants: 3, series_max_occurrences: 20)

    for days <- [7, 14, 21] do
      session =
        insert(:group_meeting,
          organizer_user_id: host.user.id,
          meeting_type_id: type.id,
          start_time: at(today, days),
          end_time: DateTime.add(at(today, days), 30, :minute),
          capacity: 3
        )

      insert(:participant, meeting: session)
    end

    {:ok, ten} = Plan.recurring(type, at(today, 7), 10)
    {:ok, twenty} = Plan.recurring(type, at(today, 7), 20)

    opts = [now: now, booker_email: "someone@example.com"]

    assert queries_during(fn -> Check.check(ten, opts) end) ==
             queries_during(fn -> Check.check(twenty, opts) end)
  end

  # The queries `fun` issues from the test process, counted through the
  # repo's telemetry.
  defp queries_during(fun) do
    test_pid = self()
    handler_id = "series-check-queries-#{inspect(make_ref())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test_pid, do: send(test_pid, {:series_check_query, handler_id})
        end,
        nil
      )

    try do
      assert {:ok, [_first | _rest]} = fun.()
    after
      :telemetry.detach(handler_id)
    end

    count_messages({:series_check_query, handler_id}, 0)
  end

  defp count_messages(message, count) do
    receive do
      ^message -> count_messages(message, count + 1)
    after
      0 -> count
    end
  end
end
