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

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.Factory
  import Tymeslot.SeatMoveTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Bookings.{CalendarCheck, CancelSeat, Create}
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup :seat_move_context

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
    assert Repo.get!(MeetingSchema, old_meeting.id).status == :cancelled

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "delete", "meeting_id" => old_meeting.id}
    )

    assert_enqueued(worker: CalendarEventWorker, args: %{"meeting_id" => new_meeting.id})
  end

  # The emptied old meeting is cancelled inside the move transaction, and its
  # status flip cannot be driven to fail through the public API (its own
  # attrs are always valid), so the failure is forced with :meck. The move
  # left the old meeting's time out of its conflict check on the promise
  # that the meeting goes with it, so a flip that fails takes the whole move
  # back: the seat stays where it was, and no new slot or job is left behind.
  test "the emptied old meeting failing to cancel rolls the whole move back",
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

    assert {:error, :failed_to_update_meeting} = result

    assert Repo.get!(MeetingSchema, old_meeting.id).status == :confirmed

    assert [%{id: mover_id, cancelled_at: nil}] =
             ParticipantQueries.list_live_for_meeting(old_meeting.id)

    assert mover_id == mover.id
    assert [_only_the_old_meeting] = Repo.all(MeetingSchema)
    refute_enqueued(worker: EmailWorker, args: %{"action" => "send_seat_reschedule_emails"})
  end

  describe "a move overlapping the seat's own meeting" do
    # An hour-long meeting at 14:00 New York time, offered every half hour,
    # so 14:30 is a slot the page offers that overlaps the meeting's second
    # half.
    setup %{user: user, meeting_type: meeting_type, base_params: base_params} do
      {:ok, meeting_type} =
        MeetingTypes.update_meeting_type(meeting_type, %{
          duration_minutes: 60,
          slot_interval_minutes: 30
        })

      hour_params =
        Map.merge(base_params, %{
          date: Date.add(Date.utc_today(), 4),
          time: "14:00",
          duration: "60min",
          meeting_type_id: meeting_type.id,
          organizer_user_id: user.id
        })

      {:ok, hour_meeting} =
        Create.execute(hour_params, %{"name" => "Hour", "email" => "hour@example.com"})

      [hour_mover] = ParticipantQueries.list_live_for_meeting(hour_meeting.id)

      %{hour_params: hour_params, hour_meeting: hour_meeting, hour_mover: hour_mover}
    end

    defp half_hour_later do
      %{
        date: Date.to_iso8601(Date.add(Date.utc_today(), 4)),
        time: "14:30",
        duration: "60min",
        user_timezone: "America/New_York"
      }
    end

    test "is allowed for the meeting's only seat, which takes the old meeting with it",
         %{hour_meeting: hour_meeting, hour_mover: hour_mover} do
      # The organiser's calendar holds the old meeting's own event, as
      # Tymeslot wrote it there; it must not block the move either.
      assert byte_size(hour_meeting.calendar_uid) > 0

      stub_calendar_events([
        %{
          uid: hour_meeting.calendar_uid,
          summary: "Hour",
          start_time: hour_meeting.start_time,
          end_time: hour_meeting.end_time
        }
      ])

      assert {:ok, %{meeting: new_meeting, created_meeting?: true}} =
               move(hour_mover, half_hour_later())

      assert DateTime.diff(new_meeting.start_time, hour_meeting.start_time, :minute) == 30
      assert Repo.get!(MeetingSchema, hour_meeting.id).status == :cancelled

      assert [%{email: "hour@example.com"}] =
               ParticipantQueries.list_live_for_meeting(new_meeting.id)

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "delete", "meeting_id" => hour_meeting.id}
      )
    end

    # With another seat on it, the old meeting goes ahead at its old time and
    # still occupies the host: a new slot overlapping it would double-book
    # them, so the move is refused and nothing changes.
    test "is refused while another seat keeps the old meeting going",
         %{hour_params: hour_params, hour_meeting: hour_meeting, hour_mover: hour_mover} do
      {:ok, _joined} =
        Create.execute(hour_params, %{"name" => "Stayer", "email" => "s@example.com"})

      assert {:error, :slot_taken} = move(hour_mover, half_hour_later())

      assert Repo.get!(MeetingSchema, hour_meeting.id).status == :confirmed

      assert ["hour@example.com", "s@example.com"] =
               hour_meeting.id
               |> ParticipantQueries.list_live_for_meeting()
               |> Enum.map(& &1.email)
               |> Enum.sort()

      refute Repo.exists?(
               from(m in MeetingSchema,
                 where: m.start_time == ^DateTime.add(hour_meeting.start_time, 30, :minute)
               )
             )
    end
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

    assert Repo.get!(MeetingSchema, old_meeting.id).status == :confirmed
  end

  # The mover booked the target slot as well (another tab): the move is
  # refused under the slot's lock, before any insert, and says why.
  test "a new slot the mover already has a seat on reports :already_booked",
       %{base_params: base_params, old_meeting: old_meeting, mover: mover} do
    target_params = Map.merge(base_params, %{date: Date.add(Date.utc_today(), 3), time: "10:00"})

    {:ok, _m} =
      Create.execute(target_params, %{"name" => "Mover", "email" => "MOVER@example.com"})

    assert {:error, :already_booked} = move(mover, new_slot_params())

    assert [%{email: "mover@example.com"}] =
             ParticipantQueries.list_live_for_meeting(old_meeting.id)
  end

  # The page offers the participant's own slot like any other with a spot
  # free; choosing it is not a move, and must not read as "already booked".
  test "moving a seat to the time it already has changes nothing and says so",
       %{old_meeting: old_meeting, mover: mover} do
    same_time = %{
      date: Date.to_iso8601(Date.add(Date.utc_today(), 2)),
      time: "14:00",
      duration: "30min",
      user_timezone: "America/New_York"
    }

    assert {:error, :seat_time_unchanged} = move(mover, same_time)

    assert {:ok, %{cancelled_at: nil}} = ParticipantQueries.get(mover.id)

    assert [%{email: "mover@example.com"}] =
             ParticipantQueries.list_live_for_meeting(old_meeting.id)

    refute_enqueued(worker: EmailWorker, args: %{"action" => "send_seat_reschedule_emails"})
  end

  test "a move drops the organiser's cached availability for both slots",
       %{user: user, mover: mover} do
    cache_key =
      AvailabilityCache.availability_range_key(
        user.id,
        Date.utc_today(),
        Date.add(Date.utc_today(), 41),
        "Etc/UTC",
        30,
        nil,
        nil
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

    assert Repo.get!(MeetingSchema, old_meeting.id).status == :confirmed

    assert [%{email: "s@example.com"}] =
             ParticipantQueries.list_live_for_meeting(old_meeting.id)

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => old_meeting.id}
    )
  end

  # A meeting's seat count is governed by its own snapshotted capacity for
  # its whole life, not by whatever `max_participants` the caller happens to
  # be carrying — see `SeatWrites.take_seat/5`. Rescheduling a seat
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
  # meetings pointing at nothing. Their seats stand, but a move would create
  # a group meeting belonging to no type, which no booking page offers and
  # no type update keeps in step, so the move is refused and the seat kept.
  test "a seat whose meeting type was deleted cannot be moved",
       %{meeting_type: meeting_type, old_meeting: old_meeting, mover: mover} do
    {:ok, _deleted} = MeetingTypes.delete_meeting_type(meeting_type)
    meetings_before = Repo.aggregate(MeetingSchema, :count)

    assert {:error, :seat_not_movable} = move(mover, new_slot_params())

    assert [%{id: id}] = ParticipantQueries.list_live_for_meeting(old_meeting.id)
    assert id == mover.id
    assert Repo.aggregate(MeetingSchema, :count) == meetings_before
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
          %{kind: :video, label: "Video call", video_integration_ids: [integration.id]}
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
    assert new_meeting.location_kind == :in_person
    assert new_meeting.location_option_id == old_meeting.location_option_id
    assert new_meeting.venue_id == venue.id
    assert new_meeting.location == "Main Hall (1 Market Square)"
    refute new_meeting.address_to_arrange
  end

  # A slot whose only seat awaits its booker's email verification is held:
  # it occupies its time but has no calendar event, reminders or room, and
  # the organiser has not heard of it. The mover's confirmed seat is its
  # first to count, so the move brings it to life, and the held seat lapsing
  # afterwards takes only that seat with it.
  test "a seat moving onto a held slot brings it to life, and the held seat lapsing leaves it standing",
       %{user: user, meeting_type: meeting_type, mover: mover} do
    start_time = new_slot_start()
    deadline = DateTime.add(DateTime.utc_now(:second), 30, :minute)

    held_slot =
      insert(:group_meeting,
        status: :awaiting_verification,
        verification_deadline_at: deadline,
        organizer_user_id: user.id,
        organizer_email: user.email,
        meeting_type_id: meeting_type.id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute),
        duration: 30,
        capacity: 2,
        reminders: [%{"value" => 1, "unit" => "hours"}]
      )

    held_seat =
      insert(:participant,
        meeting: held_slot,
        email: "held@example.com",
        verification_deadline_at: deadline
      )

    assert {:ok, %{meeting: %{id: slot_id, status: :confirmed}, participant: moved}} =
             move(mover, new_slot_params())

    assert slot_id == held_slot.id

    assert %{status: :confirmed, email_verified_at: %DateTime{}} =
             Repo.get!(MeetingSchema, slot_id)

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "create", "meeting_id" => slot_id}
    )

    refute_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => slot_id}
    )

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_reminder_emails", "meeting_id" => slot_id}
    )

    # The mover moved: they hear of it as a move, not as a new booking.
    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_seat_reschedule_emails", "participant_id" => moved.id}
    )

    refute_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_seat_confirmation_emails", "participant_id" => moved.id}
    )

    assert {:ok, _released} = EmailVerification.expire_seat(held_seat)

    assert %{status: :confirmed, cancelled_at: nil} = Repo.get!(MeetingSchema, slot_id)
    assert [%{id: moved_id}] = ParticipantQueries.list_live_for_meeting(slot_id)
    assert moved_id == moved.id
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

    assert [%{id: id, status: :cancelled}] = Repo.all(MeetingSchema)
    assert id == old_meeting.id
    assert {:ok, %{cancelled_at: %DateTime{}}} = ParticipantQueries.get(mover.id)

    refute_enqueued(worker: EmailWorker, args: %{"action" => "send_seat_reschedule_emails"})
  end
end
