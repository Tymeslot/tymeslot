defmodule Tymeslot.Bookings.RescheduleSeatIntegrationTest do
  @moduledoc """
  Integration coverage for move-my-seat: participant moves between slots in
  one transaction, both calendar events update, the participant's email
  carries a SEQUENCE-bumped cancel ICS for the old event, and a full new
  slot leaves everything untouched.

  Delivery is asserted through `Tymeslot.EmailServiceMock` (Mox) rather than
  `Swoosh.TestAssertions` — see `Tymeslot.Bookings.CancelSeatIntegrationTest`
  for the rationale: `Tymeslot.Emails.Delivery.deliver/1` runs every send
  inside the `Tymeslot.Infrastructure.CircuitBreaker` GenServer, so the
  `{:email, ...}` message Swoosh's test adapter posts never reaches the test
  process. Mocking at the `Config.email_service_module/0` boundary still
  drives the full reschedule -> job -> handler flow end to end, and lets us
  assert on the old-event snapshot (uid/sequence) handed to the email layer.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Bookings.{Create, RescheduleSeat}
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Infrastructure.AvailabilityCache
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
    _profile = insert(:profile, user: user, timezone: "America/New_York")

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        is_active: true,
        max_participants: 2
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
      meeting_type: meeting_type,
      base_params: base_params,
      old_meeting: old_meeting,
      mover: mover
    }
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
             RescheduleSeat.execute(mover.management_token, new_slot_params())

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

  test "the participant email carries the new invite plus a SEQUENCE-bumped cancel for the old event",
       %{old_meeting: old_meeting, mover: mover} do
    assert {:ok, %{meeting: new_meeting, participant: moved}} =
             RescheduleSeat.execute(mover.management_token, new_slot_params())

    expect(EmailServiceMock, :send_seat_reschedule_to_participant, fn participant_email,
                                                                      appointment_details,
                                                                      old_event ->
      assert participant_email == "mover@example.com"
      assert appointment_details.uid == new_meeting.uid
      assert appointment_details.attendee_name == "Mover"
      assert old_event.uid == old_meeting.uid
      assert old_event.ical_sequence == old_meeting.ical_sequence
      assert old_event.start_time == old_meeting.start_time
      assert old_event.end_time == old_meeting.end_time
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn organizer_email,
                                                                             _details ->
      assert organizer_email == "organizer@example.com"
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_seat_reschedule_emails",
               "meeting_id" => new_meeting.id,
               "participant_id" => moved.id,
               "old_uid" => old_meeting.uid,
               "old_ical_sequence" => old_meeting.ical_sequence,
               "old_start_time" => DateTime.to_iso8601(old_meeting.start_time),
               "old_end_time" => DateTime.to_iso8601(old_meeting.end_time)
             })
  end

  test "a full new slot changes nothing and reports :slot_taken",
       %{base_params: base_params, old_meeting: old_meeting, mover: mover} do
    # Fill the target slot completely (max_participants: 2)
    full_params = Map.merge(base_params, %{date: Date.add(Date.utc_today(), 3), time: "10:00"})
    {:ok, _m} = Create.execute(full_params, %{"name" => "A", "email" => "a@example.com"})
    {:ok, _m} = Create.execute(full_params, %{"name" => "B", "email" => "b@example.com"})

    assert {:error, :slot_taken} =
             RescheduleSeat.execute(mover.management_token, new_slot_params())

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

    assert {:ok, _booked} = RescheduleSeat.execute(mover.management_token, new_slot_params())

    assert AvailabilityCache.get_or_compute(cache_key, fn -> :recomputed end) == :recomputed
  end

  test "a seat left behind on the old slot keeps that meeting alive",
       %{base_params: base_params, old_meeting: old_meeting, mover: mover} do
    old_params = Map.merge(base_params, %{date: Date.add(Date.utc_today(), 2), time: "14:00"})
    {:ok, _joined} = Create.execute(old_params, %{"name" => "Stayer", "email" => "s@example.com"})

    assert {:ok, _booked} = RescheduleSeat.execute(mover.management_token, new_slot_params())

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

    assert {:error, :slot_taken} = RescheduleSeat.execute(mover.management_token, new_params)

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
             RescheduleSeat.execute(mover.management_token, new_slot_params())

    assert new_meeting.capacity == old_meeting.capacity
  end
end
