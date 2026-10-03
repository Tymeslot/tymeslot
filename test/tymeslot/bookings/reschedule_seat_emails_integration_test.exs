defmodule Tymeslot.Bookings.RescheduleSeatEmailsIntegrationTest do
  @moduledoc """
  The emails a seat move sends: the participant's invitation to the new seat
  with the old seat's cancellation attached, the organiser's "a participant
  moved their spot", and the old seat's cancellation and the new seat's
  invitation for the participant's guests. Each seat is its own calendar
  entry, and the old one is cancelled whatever has become of the new one.

  Delivery is asserted through `Tymeslot.EmailServiceMock`, for the reason
  `Tymeslot.Bookings.CancelSeatIntegrationTest` gives.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :emails

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox

  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]

  import Tymeslot.Factory

  alias Tymeslot.Bookings.{CancelSeat, Create, RescheduleSeat}
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
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

  defp new_slot_params do
    %{
      date: Date.to_iso8601(Date.add(Date.utc_today(), 3)),
      time: "10:00",
      duration: "30min",
      user_timezone: "America/New_York"
    }
  end

  defp reschedule_args(new_meeting, moved, mover) do
    %{
      "action" => "send_seat_reschedule_emails",
      "meeting_id" => new_meeting.id,
      "participant_id" => moved.id,
      "old_participant_id" => mover.id
    }
  end

  test "the participant email carries the new seat's invite plus a cancellation of the old seat's entry",
       %{old_meeting: old_meeting, mover: mover} do
    assert {:ok, %{meeting: new_meeting, participant: moved}} =
             move(mover, new_slot_params())

    args = reschedule_args(new_meeting, moved, mover)
    # The mover was alone on the old slot, so the move emptied and freed it.
    assert_enqueued(worker: EmailWorker, args: Map.put(args, "old_slot_freed", true))

    # Moving cancelled the old seat, a new revision of its calendar entry.
    assert {:ok, %{ical_sequence: 1, cancelled_at: %DateTime{}}} =
             ParticipantQueries.get(mover.id)

    expect(EmailServiceMock, :send_seat_reschedule_to_participant, fn participant_email,
                                                                      appointment_details,
                                                                      old_event ->
      assert participant_email == "mover@example.com"
      # Each seat is its own calendar entry: the new seat's UID is the new
      # row's, and the cancelled one is the old seat's, one revision up.
      assert appointment_details.uid == moved.id
      assert appointment_details.ical_sequence == 0
      assert appointment_details.attendee_name == "Mover"
      assert String.contains?(appointment_details.cancel_url, moved.management_token)
      assert old_event.uid == mover.id
      assert old_event.ical_sequence == 0
      assert old_event.start_time == old_meeting.start_time
      assert old_event.end_time == old_meeting.end_time
      # The time the spot moved from, as the participant reads it.
      assert DateTime.compare(old_event.start_time_attendee_tz, old_meeting.start_time) == :eq
      {:ok, "sent"}
    end)

    # The organiser hears that this participant moved their spot, from when
    # to when, and never gets the mover's seat links.
    expect(EmailServiceMock, :send_seat_update_to_organizer, fn :moved,
                                                                organizer_email,
                                                                details ->
      assert organizer_email == "organizer@example.com"
      assert details.attendee_name == "Mover"
      assert DateTime.compare(details.original_start_time_owner_tz, old_meeting.start_time) == :eq
      assert DateTime.compare(details.start_time_owner_tz, new_meeting.start_time) == :eq
      assert details.old_slot_freed == true
      refute inspect(details) =~ moved.management_token
      refute inspect(details) =~ mover.management_token
      {:ok, "sent"}
    end)

    assert :ok = perform_job(EmailWorker, Map.put(args, "old_slot_freed", true))
  end

  # The old seat's entry is still in the participant's and their guests'
  # calendars whatever has become of the new seat, so its cancellation must
  # not depend on the new seat still standing when the job runs.
  test "a seat moved and then cancelled before its emails run still cancels the old seat's entry",
       %{old_meeting: old_meeting, mover: mover} do
    {:ok, [guest]} =
      Guests.create_for_participant(old_meeting.id, mover.id, ["guest@example.com"])

    {:ok, _guest} = GuestQueries.mark_confirmation_sent(guest, DateTime.utc_now(:second))

    assert {:ok, %{meeting: new_meeting, participant: moved}} =
             move(mover, new_slot_params())

    assert {:ok, :meeting_cancelled} = CancelSeat.execute(moved.management_token)

    stub(EmailServiceMock, :send_seat_update_to_organizer, fn :moved, _email, _details ->
      {:ok, "sent"}
    end)

    # The old seat's cancellation, on its own UID, one revision up; no
    # invitation to the new seat, which has gone.
    expect(EmailServiceMock, :send_cancellation_email_to_attendee, fn email, details ->
      assert email == "mover@example.com"
      assert details.uid == mover.id
      assert details.ical_sequence == 0
      assert details.start_time == old_meeting.start_time
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_guest_cancellation, fn email, details ->
      assert email == "guest@example.com"
      assert details.uid == mover.id
      {:ok, "sent"}
    end)

    assert :ok = perform_job(EmailWorker, reschedule_args(new_meeting, moved, mover))
  end

  test "a move's emails retry only what did not go out",
       %{mover: mover} do
    assert {:ok, %{meeting: new_meeting, participant: moved}} =
             move(mover, new_slot_params())

    args = reschedule_args(new_meeting, moved, mover)

    expect(EmailServiceMock, :send_seat_reschedule_to_participant, 1, fn _email, _details, _old ->
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_seat_update_to_organizer, fn :moved, _email, _details ->
      {:error, "SMTP unavailable"}
    end)

    assert {:error, _reason} = perform_job(EmailWorker, args)

    # Only the organiser is expected this time.
    expect(EmailServiceMock, :send_seat_update_to_organizer, fn :moved, _email, _details ->
      {:ok, "sent"}
    end)

    assert :ok = perform_job(EmailWorker, args)

    assert {:ok, %{confirmation_sent_at: %DateTime{}, organizer_notified_at: %DateTime{}}} =
             ParticipantQueries.get(moved.id)
  end

  # The guests used to be re-invited to the new time while the old entry
  # stayed in their calendars, never cancelled.
  test "the mover's guests move with the seat: the old entry is cancelled and the new one invited",
       %{old_meeting: old_meeting, mover: mover} do
    {:ok, [guest]} =
      Guests.create_for_participant(old_meeting.id, mover.id, ["guest@example.com"])

    {:ok, _guest} = GuestQueries.mark_confirmation_sent(guest, DateTime.utc_now(:second))

    assert {:ok, %{meeting: new_meeting, participant: moved}} =
             move(mover, new_slot_params())

    assert [%{email: "guest@example.com", confirmation_sent_at: nil}] =
             GuestQueries.list_for_participant(moved.id)

    stub(EmailServiceMock, :send_seat_reschedule_to_participant, fn _email, _details, _old ->
      {:ok, "sent"}
    end)

    stub(EmailServiceMock, :send_seat_update_to_organizer, fn _variant, _email, _details ->
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_guest_cancellation, fn email, details ->
      assert email == "guest@example.com"
      assert details.uid == mover.id
      assert details.start_time == old_meeting.start_time
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_guest_confirmation, fn email, details ->
      assert email == "guest@example.com"
      assert details.uid == moved.id
      assert details.start_time == new_meeting.start_time
      {:ok, "sent"}
    end)

    assert :ok = perform_job(EmailWorker, reschedule_args(new_meeting, moved, mover))
  end
end
