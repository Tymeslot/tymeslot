defmodule Tymeslot.BookingSeries.CreateRaceTest do
  @moduledoc """
  A series and a single booking submitted for the same time at once,
  through the whole booking flow, on real connections staged by
  `Tymeslot.Test.RaceConductor` (see its moduledoc for why the module is
  synchronous and why `on_exit` deletes what it committed).

  Both pass every check made before the booking transaction, since neither
  booking exists yet. Each order is staged in turn: the first contender
  parks right after inserting its first meeting, holding the organiser's
  schedule lock, and the second is held until it waits on that lock, then
  finds the first one's meeting. Never a partial series.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [create_always_bookable_profile: 1]
  import Tymeslot.Test.RaceConductor, only: [unboxed: 1]

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Bookings.Create
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Occurrence
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_email_mocks()
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    {user, type} =
      unboxed(fn ->
        user = create_always_bookable_profile(timezone: "Etc/UTC").user

        type =
          insert(:meeting_type,
            user: user,
            duration_minutes: 30,
            series_mode: :recurring,
            series_frequency: :weekly,
            series_interval: 1,
            series_min_occurrences: 2,
            series_max_occurrences: 6,
            series_required: false
          )

        {user, type}
      end)

    last_job_id = unboxed(fn -> Repo.aggregate(Oban.Job, :max, :id) || 0 end)

    on_exit(fn ->
      unboxed(fn ->
        # The winner commits its follow-up jobs (reminders, calendar sync).
        Repo.delete_all(from(j in Oban.Job, where: j.id > ^last_job_id))
        Repo.delete_all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id))
        Repo.delete_all(from(s in SeriesSchema, where: s.organizer_user_id == ^user.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    RaceConductor.attach_parking()

    %{user: user, type: type, today: Date.utc_today()}
  end

  # The contested slot is the series' second session.
  setup ctx do
    contested = ctx.today |> Date.add(14) |> DateTime.new!(~T[10:00:00], "Etc/UTC")

    params = %{
      duration: 30,
      user_timezone: "Etc/UTC",
      organizer_user_id: ctx.user.id,
      meeting_type_id: ctx.type.id
    }

    series = %{mode: :recurring, first_start: DateTime.add(contested, -7, :day), count: 3}
    # A week later: its first two sessions are the first series' last two.
    later_series = %{mode: :recurring, first_start: contested, count: 3}
    single = %{date: DateTime.to_date(contested), time: "10:00"}

    %{
      contested: contested,
      book_single: fn -> Create.execute(Map.merge(params, single), form()) end,
      book_series: fn -> BookingSeries.book(Map.put(params, :series, series), form()) end,
      book_later_series: fn ->
        BookingSeries.book(Map.put(params, :series, later_series), form("other@example.com"))
      end
    }
  end

  test "the single booking takes the lock first: the series is refused whole", ctx do
    {single_result, series_result} = staged(ctx.book_single, ctx.book_series)

    assert {:ok, %MeetingSchema{}} = single_result

    assert {:error, {:occurrences_unavailable, [%Occurrence{} = lost]}} = series_result
    assert %Occurrence{position: 2, status: {:unavailable, :booked}} = lost

    {meetings, series_rows} = committed(ctx)
    contested = ctx.contested
    assert [%{series_id: nil, start_time: ^contested}] = meetings
    assert series_rows == 0
  end

  test "the series takes the lock first: the single booking is told the slot is taken", ctx do
    {series_result, single_result} = staged(ctx.book_series, ctx.book_single)

    assert {:ok, %{meetings: booked}} = series_result
    assert length(booked) == 3
    assert single_result == {:error, :slot_taken}

    {meetings, series_rows} = committed(ctx)
    assert length(meetings) == 3
    assert Enum.all?(meetings, &(&1.series_id != nil))
    assert series_rows == 1
  end

  # The losing series' transaction stops at the first session it finds
  # taken; the booker is still told of every session the winner took, so
  # they re-pick once rather than once per clash.
  test "two overlapping series: the loser learns every session it lost at once", ctx do
    {first_result, second_result} = staged(ctx.book_series, ctx.book_later_series)

    assert {:ok, %{meetings: [_first, _second, _third]}} = first_result
    assert {:error, {:occurrences_unavailable, lost}} = second_result

    assert [
             %Occurrence{position: 1, status: {:unavailable, :booked}},
             %Occurrence{position: 2, status: {:unavailable, :booked}}
           ] = lost

    {meetings, series_rows} = committed(ctx)
    assert length(meetings) == 3
    assert series_rows == 1
  end

  # The second look reads the calendars again; when it cannot, the session
  # the transaction met is still reported, as it found it.
  test "the loser still learns the session it met when the second look fails", ctx do
    fail_calendars = fn ->
      stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:error, :timeout}
      end)
    end

    {first_result, second_result} =
      staged(ctx.book_series, ctx.book_later_series, fail_calendars)

    assert {:ok, %{meetings: [_first, _second, _third]}} = first_result

    assert {:error, {:occurrences_unavailable, [%Occurrence{position: 1} = lost]}} =
             second_result

    assert lost.status == {:unavailable, :booked}
  end

  # Runs `first` until it has inserted its first meeting, holding the
  # organiser's schedule lock, then starts `second` and waits until it is
  # blocked on that lock, before running `before_release` and letting
  # `first` commit. Either step not happening fails the test, so the race is
  # always the one staged.
  defp staged(first, second, before_release \\ fn -> :ok end) do
    test_pid = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(
            RaceConductor.park_here(test_pid),
            RaceConductor.insert_into("meetings")
          )

          first.()
        end)
      end)

    assert_receive {:parked, holder_pid}, 10_000

    waiter = Task.async(fn -> unboxed(second) end)
    assert RaceConductor.await_finished_or_blocked(waiter) == :blocked

    before_release.()
    send(holder_pid, :release)
    {Task.await(holder, 30_000), Task.await(waiter, 30_000)}
  end

  defp committed(ctx) do
    unboxed(fn ->
      {Repo.all(from(m in MeetingSchema, where: m.organizer_user_id == ^ctx.user.id)),
       Repo.aggregate(from(s in SeriesSchema, where: s.organizer_user_id == ^ctx.user.id), :count)}
    end)
  end

  defp form(email \\ "racer@example.com"),
    do: %{"name" => "Racer", "email" => email, "message" => ""}
end
