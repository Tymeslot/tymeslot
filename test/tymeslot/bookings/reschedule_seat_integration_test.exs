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
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
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
end
