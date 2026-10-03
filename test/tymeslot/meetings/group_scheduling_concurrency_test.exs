defmodule Tymeslot.Meetings.GroupSchedulingConcurrencyTest do
  @moduledoc """
  Races on group seats, on real connections.

  The sandbox cannot show these races: it gives a test one connection, so
  "concurrent" transactions queue on it and each sees the previous one
  committed, whether or not the code takes the row locks it relies on. Each
  contender here therefore runs on its own connection
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`) and commits for real, which is
  why the module is synchronous and why `on_exit` deletes what it committed.

  The races are staged rather than left to timing. Every contender parks
  inside its seat transaction once it holds a seat (through `book_seat/3`'s
  `:on_booked` hook), and the conductor releases the parked ones only when
  every unfinished contender is either parked or waiting on a database lock,
  that is, when nobody can get any further before somebody commits. With the
  row locks in place a single contender parks at a time and the rest queue
  behind it; without them every contender reads the same free seats, parks,
  and all of them commit.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.Factory

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.UUID
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Bookings.RescheduleSeat
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @capacity 3

  setup do
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    {user, meeting_type} =
      unboxed(fn ->
        user = insert(:user)
        open_schedule_for(insert(:profile, user: user))
        {user, insert(:meeting_type, user: user, max_participants: @capacity)}
      end)

    on_exit(fn ->
      unboxed(fn ->
        meeting_ids =
          Repo.all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id, select: m.id))

        # A seat move commits its follow-up jobs (emails, calendar sync).
        Repo.delete_all(
          from(j in Oban.Job, where: fragment("?->>'meeting_id'", j.args) in ^meeting_ids)
        )

        Repo.delete_all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    %{user: user, meeting_type: meeting_type}
  end

  test "bookers racing for the last seat: exactly one gets it", ctx do
    slot = slot_at(ctx, 6)

    meeting =
      unboxed(fn ->
        {:ok, %{meeting: meeting}} = book(slot, "first@example.com")
        {:ok, _booking} = book(slot, "second@example.com")
        meeting
      end)

    results =
      race(
        for n <- 1..4 do
          fn hold -> book(slot, "racer-#{n}@example.com", on_booked: hold) end
        end
      )

    assert Enum.count(results, &match?({:ok, %{created_meeting?: false}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :slot_full}, &1)) == 3

    assert unboxed(fn -> length(ParticipantQueries.list_live_for_meeting(meeting.id)) end) ==
             @capacity
  end

  test "first bookers racing for an empty slot share one meeting up to its capacity", ctx do
    slot = slot_at(ctx, 7)

    results =
      race(
        for n <- 1..5 do
          fn hold -> book(slot, "first-#{n}@example.com", on_booked: hold) end
        end
      )

    assert Enum.count(results, &match?({:ok, %{created_meeting?: true}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{created_meeting?: false}}, &1)) == @capacity - 1
    assert Enum.count(results, &match?({:error, :slot_full}, &1)) == 5 - @capacity

    assert [meeting] =
             unboxed(fn ->
               Repo.all(from(m in MeetingSchema, where: m.organizer_user_id == ^ctx.user.id))
             end)

    assert unboxed(fn -> length(ParticipantQueries.list_live_for_meeting(meeting.id)) end) ==
             @capacity
  end

  # Drives `Tymeslot.Bookings.RescheduleSeat` itself: the new seat is booked
  # with the old meeting passed as `:also_lock`, and the old seat is cancelled
  # from inside the seat transaction under the old meeting's row lock. Two
  # moves in opposite directions each want both rows; taken in id order they
  # queue, taken target first they deadlock. The move has no hook of its own,
  # so each contender parks once its new seat is inserted (`park_on_seat/1`),
  # the point `:on_booked` would hold it at.
  test "two seat moves in opposite directions both complete", ctx do
    slot_a = slot_at(ctx, 8)
    slot_b = slot_at(ctx, 9)

    {meeting_a, mover_a, meeting_b, mover_b} =
      unboxed(fn ->
        {:ok, %{meeting: meeting_a, participant: mover_a}} = book(slot_a, "mover-a@example.com")
        {:ok, _stays} = book(slot_a, "stays-a@example.com")
        {:ok, %{meeting: meeting_b, participant: mover_b}} = book(slot_b, "mover-b@example.com")
        {:ok, _stays} = book(slot_b, "stays-b@example.com")
        {meeting_a, mover_a, meeting_b, mover_b}
      end)

    park_on_seat()

    results =
      race([
        fn hold -> move(mover_a, slot_b, hold) end,
        fn hold -> move(mover_b, slot_a, hold) end
      ])

    assert [{:ok, _move_a}, {:ok, _move_b}] = results

    live_emails = fn meeting ->
      unboxed(fn ->
        meeting.id
        |> ParticipantQueries.list_live_for_meeting()
        |> Enum.map(& &1.email)
        |> Enum.sort()
      end)
    end

    assert live_emails.(meeting_a) == ["mover-b@example.com", "stays-a@example.com"]
    assert live_emails.(meeting_b) == ["mover-a@example.com", "stays-b@example.com"]
  end

  defp move(participant, new_slot, hold) do
    Process.put(:park_on_seat, hold)

    RescheduleSeat.execute(
      participant.management_token,
      %{
        date: Date.to_iso8601(DateTime.to_date(new_slot.start_time)),
        time: "09:00",
        duration: "30",
        user_timezone: "Etc/UTC"
      },
      new_slot.user.id
    )
  end

  # Parks a contender (a process that stored its `hold` under
  # `:park_on_seat`) right after it inserts its new participant row, inside
  # the seat transaction, once.
  defp park_on_seat do
    handler_id = "park-on-seat-#{inspect(make_ref())}"

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        with "meeting_participants" <- metadata[:source],
             "INSERT" <> _rest <- metadata[:query],
             hold when is_function(hold, 1) <- Process.delete(:park_on_seat) do
          {:ok, :released} = hold.(nil)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp slot_at(ctx, days_ahead) do
    start_time =
      DateTime.utc_now()
      |> DateTime.add(days_ahead, :day)
      |> then(&%{&1 | hour: 9, minute: 0, second: 0, microsecond: {0, 0}})

    %{user: ctx.user, meeting_type: ctx.meeting_type, start_time: start_time}
  end

  defp book(slot, email, opts \\ []) do
    GroupScheduling.book_seat(
      %{
        uid: UUID.generate(),
        title: slot.meeting_type.name,
        start_time: slot.start_time,
        end_time: DateTime.add(slot.start_time, 30, :minute),
        duration: 30,
        status: "confirmed",
        organizer_user_id: slot.user.id,
        organizer_name: "Organiser",
        organizer_email: "organiser@example.com",
        meeting_type_id: slot.meeting_type.id
      },
      %{
        participant: %{
          name: "Booker #{email}",
          email: email,
          timezone: "Etc/UTC",
          locale: "en",
          custom_field_answers: %{}
        },
        guest_emails: [],
        max_participants: @capacity
      },
      opts
    )
  end

  # Runs each contender on its own connection. A contender is given a `hold`
  # hook to call inside its transaction; the call parks it until released.
  # Returns each contender's result, in order; a raised error (a deadlock
  # Postgres broke by aborting one side) comes back as `{:raised, error}`.
  defp race(contenders) do
    conductor = self()

    hold = fn _booking ->
      send(conductor, {:parked, self()})

      receive do
        :release -> {:ok, :released}
      end
    end

    tasks =
      Enum.map(contenders, fn contender ->
        Task.async(fn ->
          unboxed(fn ->
            try do
              contender.(hold)
            rescue
              error -> {:raised, error}
            end
          end)
        end)
      end)

    tasks
    |> conduct(%{}, [], System.monotonic_time(:millisecond) + 30_000)
    |> then(fn results -> Enum.map(tasks, &Map.fetch!(results, &1.ref)) end)
  end

  defp conduct(pending, results, parked, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: flunk("race did not settle")

    {pending, results} = collect_finished(pending, results)
    parked = drain_parked(parked)

    cond do
      pending == [] ->
        results

      parked != [] and length(parked) + lock_waiters() >= length(pending) ->
        Enum.each(parked, &send(&1, :release))
        conduct(pending, results, [], deadline)

      true ->
        receive do
          {:parked, pid} -> conduct(pending, results, [pid | parked], deadline)
        after
          10 -> conduct(pending, results, parked, deadline)
        end
    end
  end

  defp collect_finished(pending, results) do
    Enum.reduce(pending, {[], results}, fn task, {still_pending, results} ->
      case Task.yield(task, 0) do
        {:ok, result} -> {still_pending, Map.put(results, task.ref, result)}
        nil -> {[task | still_pending], results}
      end
    end)
  end

  defp drain_parked(parked) do
    receive do
      {:parked, pid} -> drain_parked([pid | parked])
    after
      0 -> parked
    end
  end

  defp lock_waiters do
    %{rows: [[count]]} =
      unboxed(fn ->
        SQL.query!(
          Repo,
          "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'",
          []
        )
      end)

    count
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
