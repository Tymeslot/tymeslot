defmodule Tymeslot.Bookings.RescheduleSeatIntegrationTest do
  @moduledoc """
  Integration coverage for move-my-seat: participant moves between slots in
  one transaction, both calendar events update, and a full new slot leaves
  everything untouched. The emails a move sends are covered by
  `Tymeslot.Bookings.RescheduleSeatEmailsIntegrationTest`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox

  import Tymeslot.AvailabilityTestHelpers,
    only: [open_schedule_for: 1, create_bookable_profile: 1, next_bookable_weekday: 0]

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Bookings.{CalendarCheck, CancelSeat, Create, RescheduleSeat}
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "organizer@example.com", name: "Test Organizer")
    profile = insert(:profile, user: user, timezone: "America/New_York")

    # The seat move is this test's subject, not availability: the host offers
    # every hour of every day so the schedule is never why a booking is refused.
    open_schedule_for(profile)

    # A group type's location is fixed in advance: one venue.
    venue = insert(:venue, user: user, name: "Main Hall", description: "1 Market Square")

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        is_active: true,
        max_participants: 2,
        locations: [in_person_location([venue])]
      )

    base_params = %{
      duration: "30min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    old_params = Map.merge(base_params, %{date: Date.add(Date.utc_today(), 2), time: "14:00"})

    {:ok, old_meeting} =
      Create.execute(old_params, %{"name" => "Mover", "email" => "mover@example.com"})

    mover =
      old_meeting.id
      |> ParticipantQueries.list_live_for_meeting()
      |> Enum.find(&(&1.email == "mover@example.com"))

    %{
      user: user,
      venue: venue,
      meeting_type: meeting_type,
      base_params: base_params,
      old_meeting: old_meeting,
      mover: mover
    }
  end

  # Submitted from the seat's own organiser's booking page, as the seat
  # reschedule link sends it.
  defp move(participant, params) do
    organizer_user_id = Repo.get!(MeetingSchema, participant.meeting_id).organizer_user_id
    RescheduleSeat.execute(participant.management_token, params, organizer_user_id)
  end

  defp new_slot_start do
    Date.utc_today()
    |> Date.add(3)
    |> DateTime.new!(~T[10:00:00], "America/New_York")
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp busy_event(uid, start_time) do
    %{
      uid: uid,
      summary: "Busy",
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute)
    }
  end

  defp stub_calendar_events(events) do
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, events}
    end)
  end

  defp new_slot_params do
    %{
      date: Date.to_iso8601(Date.add(Date.utc_today(), 3)),
      time: "10:00",
      duration: "30min",
      user_timezone: "America/New_York"
    }
  end

  test "moves the seat, cancels the emptied old meeting, and updates both calendar events",
       %{old_meeting: old_meeting, mover: mover} do
    assert {:ok, %{meeting: new_meeting}} =
             move(mover, new_slot_params())

    assert new_meeting.id != old_meeting.id

    # Old participant row is cancelled, new live row exists on the new meeting
    assert ParticipantQueries.list_live_for_meeting(old_meeting.id) == []

    assert [%{email: "mover@example.com", cancelled_at: nil}] =
             ParticipantQueries.list_live_for_meeting(new_meeting.id)

    # Old meeting was emptied by the move, so it is cancelled and its event deleted
    assert Repo.get!(MeetingSchema, old_meeting.id).status == "cancelled"

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "delete", "meeting_id" => old_meeting.id}
    )

    assert_enqueued(worker: CalendarEventWorker, args: %{"meeting_id" => new_meeting.id})
  end

  # `SeatRelease.release/1` cannot be driven into its error branch through
  # the public API (its own status-transition attrs are always valid), so
  # the failure is forced with :meck. The move itself must still succeed —
  # only the old meeting's emptiness check failed — and the old meeting
  # must be treated the same as "seats remain" (calendar refreshed, not
  # left stale), never crash the caller.
  test "the old meeting's emptiness check failing does not crash the move and still refreshes its calendar event",
       %{old_meeting: old_meeting, mover: mover} do
    :meck.new(MeetingQueries, [:passthrough])

    :meck.expect(MeetingQueries, :update_meeting_status, fn meeting, attrs ->
      if meeting.id == old_meeting.id do
        changeset =
          %MeetingSchema{}
          |> Changeset.change()
          |> Changeset.add_error(:status, "simulated failure")

        {:error, changeset}
      else
        :meck.passthrough([meeting, attrs])
      end
    end)

    result =
      try do
        move(mover, new_slot_params())
      after
        :meck.unload(MeetingQueries)
      end

    assert {:ok, %{meeting: new_meeting}} = result

    # The status flip rolled back — the old meeting is still confirmed, not
    # cancelled and not left in some third, undefined state.
    assert Repo.get!(MeetingSchema, old_meeting.id).status == "confirmed"

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => old_meeting.id}
    )

    assert_enqueued(worker: CalendarEventWorker, args: %{"meeting_id" => new_meeting.id})
  end

  test "a full new slot changes nothing and reports :slot_taken",
       %{base_params: base_params, old_meeting: old_meeting, mover: mover} do
    # Fill the target slot completely (max_participants: 2)
    full_params = Map.merge(base_params, %{date: Date.add(Date.utc_today(), 3), time: "10:00"})
    {:ok, _m} = Create.execute(full_params, %{"name" => "A", "email" => "a@example.com"})
    {:ok, _m} = Create.execute(full_params, %{"name" => "B", "email" => "b@example.com"})

    assert {:error, :slot_taken} =
             move(mover, new_slot_params())

    # Atomicity: the old seat still stands
    assert [%{email: "mover@example.com"}] =
             ParticipantQueries.list_live_for_meeting(old_meeting.id)

    assert Repo.get!(MeetingSchema, old_meeting.id).status == "confirmed"
  end

  test "a move drops the organiser's cached availability for both slots",
       %{user: user, mover: mover} do
    cache_key =
      AvailabilityCache.availability_range_key(
        user.id,
        Date.utc_today(),
        Date.add(Date.utc_today(), 41),
        "Etc/UTC",
        30
      )

    AvailabilityCache.put(cache_key, {:ok, %{"seeded" => true}})

    assert {:ok, _booked} = move(mover, new_slot_params())

    assert AvailabilityCache.get_or_compute(cache_key, fn -> :recomputed end) == :recomputed
  end

  test "a seat left behind on the old slot keeps that meeting alive",
       %{base_params: base_params, old_meeting: old_meeting, mover: mover} do
    old_params = Map.merge(base_params, %{date: Date.add(Date.utc_today(), 2), time: "14:00"})
    {:ok, _joined} = Create.execute(old_params, %{"name" => "Stayer", "email" => "s@example.com"})

    assert {:ok, _booked} = move(mover, new_slot_params())

    assert Repo.get!(MeetingSchema, old_meeting.id).status == "confirmed"

    assert [%{email: "s@example.com"}] =
             ParticipantQueries.list_live_for_meeting(old_meeting.id)

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => old_meeting.id}
    )
  end

  # A meeting's seat count is governed by its own snapshotted capacity for
  # its whole life, not by whatever `max_participants` the caller happens to
  # be carrying — see `GroupScheduling.join_meeting/3`. Rescheduling a seat
  # out of a big slot into a smaller existing one used to fill the target to
  # the *old* slot's capacity.
  test "rescheduling into a smaller existing slot is capped by that slot's own capacity",
       %{user: user, meeting_type: meeting_type} do
    {:ok, meeting_type} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 10})

    big_params = %{
      date: Date.add(Date.utc_today(), 6),
      time: "09:00",
      duration: "30min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    {:ok, big_meeting} =
      Create.execute(big_params, %{"name" => "Mover", "email" => "mover-big@example.com"})

    mover =
      big_meeting.id
      |> ParticipantQueries.list_live_for_meeting()
      |> Enum.find(&(&1.email == "mover-big@example.com"))

    {:ok, meeting_type} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 2})

    small_params = %{
      date: Date.add(Date.utc_today(), 7),
      time: "11:00",
      duration: "30min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    {:ok, small_meeting} =
      Create.execute(small_params, %{"name" => "A", "email" => "a-small@example.com"})

    {:ok, _b} = Create.execute(small_params, %{"name" => "B", "email" => "b-small@example.com"})

    assert small_meeting.capacity == 2

    new_params = %{
      date: Date.to_iso8601(Date.add(Date.utc_today(), 7)),
      time: "11:00",
      duration: "30min",
      user_timezone: "America/New_York"
    }

    assert {:error, :slot_taken} = move(mover, new_params)

    # Atomicity: the old seat still stands, and the (already full) target
    # meeting was not overfilled to the old slot's capacity of 10.
    assert [%{email: "mover-big@example.com"}] =
             ParticipantQueries.list_live_for_meeting(big_meeting.id)

    assert length(ParticipantQueries.list_live_for_meeting(small_meeting.id)) == 2
  end

  # `meetings.meeting_type_id` is nilify_all, so deleting a type leaves live
  # meetings pointing at nothing. Capacity used to be read live off that
  # association (a MatchError there once took the booking LiveView down with
  # it); it is now snapshotted onto the meeting row at creation, so a deleted
  # meeting type no longer affects an in-flight seat move at all.
  test "a deleted meeting type does not block moving an already-booked seat",
       %{meeting_type: meeting_type, old_meeting: old_meeting, mover: mover} do
    {:ok, _deleted} = MeetingTypes.delete_meeting_type(meeting_type)

    assert {:ok, %{meeting: new_meeting}} =
             move(mover, new_slot_params())

    assert new_meeting.capacity == old_meeting.capacity
  end

  # A seat move that lands on a time with no live group meeting used to
  # hand-build the new slot from ten fields, dropping the video integration,
  # description and reminder configuration a fresh booking would carry — and
  # `after_commit/3` scheduled only the calendar job, so nobody on that slot
  # ever got a reminder.
  test "a seat move creating a brand-new slot inherits the meeting type's video integration, description, and reminders",
       %{user: user, meeting_type: meeting_type, mover: mover} do
    integration = insert(:video_integration, user: user, provider: "mirotalk")

    {:ok, meeting_type} =
      MeetingTypes.update_meeting_type(meeting_type, %{
        locations: [
          %{kind: "video", label: "Video call", video_integration_ids: [integration.id]}
        ]
      })

    assert {:ok, %{meeting: new_meeting}} =
             move(mover, new_slot_params())

    assert new_meeting.video_integration_id == integration.id
    assert new_meeting.description == meeting_type.description

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_reminder_emails", "meeting_id" => new_meeting.id}
    )
  end

  # A group type's location is fixed in advance, so the slot a seat move
  # creates is held where every other slot of the type is: the type's one
  # location, at its one venue, with nothing taken from the mover.
  test "a seat move creating a brand-new slot is held at the meeting type's fixed location",
       %{venue: venue, old_meeting: old_meeting, mover: mover} do
    assert old_meeting.venue_id == venue.id

    assert {:ok, %{meeting: new_meeting, created_meeting?: true}} =
             move(mover, new_slot_params())

    assert new_meeting.id != old_meeting.id
    assert new_meeting.location_kind == "in_person"
    assert new_meeting.location_option_id == old_meeting.location_option_id
    assert new_meeting.venue_id == venue.id
    assert new_meeting.location == "Main Hall (1 Market Square)"
    refute new_meeting.address_to_arrange
  end

  describe "the move is checked like a booking of the new time" do
    test "a move submitted from another organiser's booking page is refused",
         %{old_meeting: old_meeting, mover: mover} do
      other_organizer = insert(:user)

      assert {:error, :meeting_not_found} =
               RescheduleSeat.execute(
                 mover.management_token,
                 new_slot_params(),
                 other_organizer.id
               )

      assert [%{id: id}] = ParticipantQueries.list_live_for_meeting(old_meeting.id)
      assert id == mover.id
      assert Repo.aggregate(MeetingSchema, :count) == 1
    end

    test "the seat keeps the old meeting's length whatever duration the request carries",
         %{old_meeting: old_meeting, mover: mover} do
      assert {:ok, %{meeting: new_meeting, created_meeting?: true}} =
               move(mover, %{new_slot_params() | duration: "120min"})

      assert new_meeting.duration == old_meeting.duration
      assert DateTime.diff(new_meeting.end_time, new_meeting.start_time, :minute) == 30
    end

    test "a time the organiser's calendar has since blocked is refused",
         %{old_meeting: old_meeting, mover: mover} do
      stub_calendar_events([busy_event("someone-elses-event", new_slot_start())])

      assert {:error, :slot_taken} = move(mover, new_slot_params())

      assert [%{id: id}] = ParticipantQueries.list_live_for_meeting(old_meeting.id)
      assert id == mover.id
      assert Repo.aggregate(MeetingSchema, :count) == 1
    end

    test "joining a live slot is not refused by that slot's own calendar event",
         %{base_params: base_params, old_meeting: old_meeting, mover: mover} do
      target_params =
        Map.merge(base_params, %{date: Date.add(Date.utc_today(), 3), time: "10:00"})

      {:ok, target} = Create.execute(target_params, %{"name" => "T", "email" => "t@example.com"})

      stub_calendar_events([busy_event(target.calendar_uid, target.start_time)])

      assert {:ok, %{meeting: joined, created_meeting?: false}} =
               move(mover, new_slot_params())

      assert joined.id == target.id
      assert ParticipantQueries.list_live_for_meeting(old_meeting.id) == []
    end
  end

  # The old seat is cancelled inside the move's transaction under the old
  # meeting's row lock, re-reading the seat there. A cancellation that lands
  # after the move's own up-front checks but before its transaction must win
  # alone: the move fails and takes no seat at the new slot.
  test "a seat cancelled while its move is in flight is not moved as well",
       %{old_meeting: old_meeting, mover: mover} do
    :meck.new(CalendarCheck, [:passthrough])

    :meck.expect(CalendarCheck, :enforce, fn slot, config, opts ->
      {:ok, :meeting_cancelled} = CancelSeat.execute(mover.management_token)
      :meck.passthrough([slot, config, opts])
    end)

    result =
      try do
        move(mover, new_slot_params())
      after
        :meck.unload(CalendarCheck)
      end

    assert {:error, :already_cancelled} = result

    assert [%{id: id, status: "cancelled"}] = Repo.all(MeetingSchema)
    assert id == old_meeting.id
    assert {:ok, %{cancelled_at: %DateTime{}}} = ParticipantQueries.get(mover.id)

    refute_enqueued(worker: EmailWorker, args: %{"action" => "send_seat_reschedule_emails"})
  end

  # `Validation.prepare_new_times/2` never ran `ScheduleCheck`, so a seat
  # move could land outside the organiser's own working hours — an
  # unauthenticated seat-token holder could confirm a meeting the organiser
  # never offered.
  describe "schedule enforcement" do
    setup do
      %{user: user} =
        create_bookable_profile(
          hours: %{is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00]}
        )

      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          is_active: true,
          max_participants: 2
        )

      date = next_bookable_weekday()

      old_params = %{
        date: date,
        time: "10:00",
        duration: "30min",
        user_timezone: "Etc/UTC",
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      }

      {:ok, old_meeting} =
        Create.execute(old_params, %{"name" => "Mover", "email" => "mover-hours@example.com"})

      mover =
        old_meeting.id
        |> ParticipantQueries.list_live_for_meeting()
        |> Enum.find(&(&1.email == "mover-hours@example.com"))

      %{old_meeting: old_meeting, mover: mover, date: date}
    end

    test "a seat move to a time outside the organiser's schedule is refused",
         %{old_meeting: old_meeting, mover: mover, date: date} do
      outside_hours_params = %{
        date: Date.to_iso8601(date),
        time: "22:00",
        duration: "30min",
        user_timezone: "Etc/UTC"
      }

      assert {:error, :slot_taken} =
               move(mover, outside_hours_params)

      # Atomicity: the old seat still stands
      assert [%{email: "mover-hours@example.com"}] =
               ParticipantQueries.list_live_for_meeting(old_meeting.id)
    end
  end
end
