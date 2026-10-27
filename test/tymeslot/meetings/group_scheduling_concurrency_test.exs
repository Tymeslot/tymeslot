defmodule Tymeslot.Meetings.GroupSchedulingConcurrencyTest do
  @moduledoc """
  Races on group seats, on real connections, staged by
  `Tymeslot.Test.RaceConductor` (see its moduledoc for why the module is
  synchronous and why `on_exit` deletes what it committed).

  Every contender parks inside its seat transaction once it holds a seat
  (through `book_seat/3`'s `:on_booked` hook). With the row locks in place a
  single contender parks at a time and the rest queue behind it; without
  them every contender reads the same free seats, parks, and all of them
  commit.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Ecto.UUID
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Bookings.RescheduleSeat
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor
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

  # The other interleaving of two first bookers: the late one reads the slot
  # empty and the early one tries to book before the late one's conflict
  # check runs. The late booker already holds the organiser's schedule lock,
  # so the early one queues behind it instead of committing in between, and
  # then finds the late one's meeting and joins it, with seats still free.
  test "a first booker that reads the slot empty keeps it until it commits", ctx do
    slot = slot_at(ctx, 10)
    park_after_slot_read()
    conductor = self()

    late =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:park_after_slot_read, fn ->
            send(conductor, {:parked, self()})

            receive do
              :release -> :ok
            end
          end)

          book(slot, "late@example.com")
        end)
      end)

    assert_receive {:parked, late_pid}, 5_000

    early = Task.async(fn -> unboxed(fn -> book(slot, "early@example.com") end) end)

    # Queued on the schedule lock, not committing past the parked booker.
    assert Task.yield(early, 500) == nil

    send(late_pid, :release)

    assert {:ok, %{created_meeting?: true, meeting: meeting}} = Task.await(late, 30_000)
    assert {:ok, %{created_meeting?: false, meeting: joined}} = Task.await(early, 30_000)
    assert joined.id == meeting.id

    assert ["early@example.com", "late@example.com"] =
             unboxed(fn ->
               meeting.id
               |> ParticipantQueries.list_live_for_meeting()
               |> Enum.map(& &1.email)
               |> Enum.sort()
             end)
  end

  # Parks a contender (a process that stored a zero-arity hold under
  # `:park_after_slot_read`) right after its seat transaction's locked read
  # of the slot (`GroupMeetingQueries.get_live_for_update/2`), once.
  defp park_after_slot_read do
    handler_id = "park-after-slot-read-#{inspect(make_ref())}"

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        with "meetings" <- metadata[:source],
             query when is_binary(query) <- metadata[:query],
             true <- query =~ "FOR UPDATE" and not (query =~ "NOWAIT"),
             hold when is_function(hold, 0) <- Process.delete(:park_after_slot_read) do
          hold.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Drives `Tymeslot.Bookings.RescheduleSeat` itself: the new seat is booked
  # with the old meeting passed as `:also_lock`, and the old seat is cancelled
  # from inside the seat transaction under the old meeting's row lock. Two
  # moves in opposite directions each want both rows; taken in id order they
  # queue, taken target first they deadlock. The move has no hook of its own,
  # so each contender parks once its new seat is inserted
  # (`RaceConductor.arm/2`), the point `:on_booked` would hold it at.
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

    RaceConductor.attach_parking()

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

  # A seat move onto an empty slot locks the old meeting's row and then
  # creates the new slot under the organiser's schedule lock; the organiser
  # rescheduling that old meeting holds the schedule lock and then writes the
  # row. Unless the move takes the schedule lock before the row, each holds
  # what the other waits for. The move parks once it holds the old row, the
  # reschedule once it holds the schedule lock.
  test "a seat move and a reschedule of the meeting it leaves both complete", ctx do
    slot_a = slot_at(ctx, 10)
    slot_c = slot_at(ctx, 11)
    new_start = slot_at(ctx, 12).start_time

    {meeting_a, mover} =
      unboxed(fn ->
        {:ok, %{meeting: meeting_a, participant: mover}} = book(slot_a, "mover@example.com")
        {:ok, _stays} = book(slot_a, "stays@example.com")
        {meeting_a, mover}
      end)

    RaceConductor.attach_parking()

    results =
      race([
        fn hold -> move(mover, slot_c, hold, RaceConductor.lock_of("meetings")) end,
        fn hold ->
          RaceConductor.arm(hold, RaceConductor.advisory_lock())

          Scheduling.update_meeting_with_conflict_check(meeting_a, %{
            start_time: new_start,
            end_time: DateTime.add(new_start, 30, :minute)
          })
        end
      ])

    assert [{:ok, %{created_meeting?: true}}, {:ok, %MeetingSchema{}}] = results
    assert unboxed(fn -> Repo.get!(MeetingSchema, meeting_a.id).start_time end) == new_start
  end

  defp move(
         participant,
         new_slot,
         hold,
         park_at \\ RaceConductor.insert_into("meeting_participants")
       ) do
    RaceConductor.arm(hold, park_at)

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
end
