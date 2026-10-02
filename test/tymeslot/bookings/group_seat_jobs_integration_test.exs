defmodule Tymeslot.Bookings.GroupSeatJobsIntegrationTest do
  @moduledoc """
  Integration coverage for how a group meeting's per-seat email jobs behave
  over time: each logical email is its own job (a reminder per offset, a
  reschedule request per request), a job sent to two recipients retries only
  what did not go out, a job re-checks its seat when it runs, each seat is its
  own calendar entry, and the organiser-only cancellation of an emptied
  meeting keeps the delivery failure the worker acts on.

  Delivery is asserted through `Tymeslot.EmailServiceMock`, for the reason
  `Tymeslot.Bookings.GroupBookingEmailsIntegrationTest` gives.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :emails

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.CancelSeat
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Emails.Templates.AppointmentCancellation
  alias Tymeslot.Emails.Templates.AppointmentConfirmation
  alias Tymeslot.Emails.Templates.SeatUpdateForOrganizer
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.EmailWorkerHandlers.SeatEmails

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "organizer@example.com", name: "Test Organizer")
    profile = insert(:profile, user: user, timezone: "America/New_York")
    open_schedule_for(profile)

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Group Workshop",
        duration_minutes: 30,
        is_active: true,
        max_participants: 3,
        allow_guests: true
      )

    tomorrow = Date.add(Date.utc_today(), 1)

    meeting_params = %{
      date: tomorrow,
      time: "14:00",
      duration: "30min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    %{user: user, meeting_type: meeting_type, meeting_params: meeting_params}
  end

  defp book_seat!(meeting_params, name, email) do
    assert {:ok, meeting} =
             Create.execute(meeting_params, %{
               "name" => name,
               "email" => email,
               "message" => "Count me in"
             })

    meeting
  end

  defp participant_id!(meeting_id, email) do
    meeting_id
    |> ParticipantQueries.list_live_for_meeting()
    |> Enum.find(&(&1.email == email))
    |> Map.fetch!(:id)
  end

  defp seat_jobs(action, participant_id) do
    EmailWorker
    |> then(&all_enqueued(worker: &1))
    |> Enum.filter(&(&1.args["action"] == action and &1.args["participant_id"] == participant_id))
  end

  describe "seat jobs name each logical email" do
    # A meeting with reminders at one hour and at 15 minutes owes every
    # participant two reminders. Uniqueness on (action, meeting, participant)
    # alone made the second offset's seat job a duplicate of the first, so
    # participants only ever got one of them.
    test "a reminder at each configured offset reaches every participant, and a re-run dispatch adds nothing",
         %{meeting_params: meeting_params} do
      meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
      first_id = participant_id!(meeting.id, "first@example.com")

      stub(EmailServiceMock, :send_appointment_reminder_to_organizer, fn _email, _details ->
        {:ok, "sent"}
      end)

      for {value, unit} <- [{1, "hours"}, {15, "minutes"}] do
        assert :ok =
                 perform_job(EmailWorker, %{
                   "action" => "send_reminder_emails",
                   "meeting_id" => meeting.id,
                   "reminder_value" => value,
                   "reminder_unit" => unit
                 })
      end

      offsets =
        "send_seat_reminder"
        |> seat_jobs(first_id)
        |> Enum.map(&{&1.args["reminder_value"], &1.args["reminder_unit"]})
        |> Enum.sort()

      assert offsets == [{1, "hours"}, {15, "minutes"}]

      # The same offset dispatched again is the same email.
      assert :ok =
               EmailScheduler.schedule_seat_reminder_email(meeting.id, first_id, 15, "minutes")

      assert length(seat_jobs("send_seat_reminder", first_id)) == 2
    end

    # A second reschedule request from the host is a new email, even within
    # the hour the per-seat jobs stay unique for; a re-run of the dispatch for
    # the same request is not.
    test "a later reschedule request reaches participants again, a re-run of the same one does not",
         %{meeting_params: meeting_params} do
      meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
      first_id = participant_id!(meeting.id, "first@example.com")

      request = fn requested_at ->
        assert {:ok, _meeting} =
                 meeting.id
                 |> MeetingQueries.get_meeting()
                 |> elem(1)
                 |> MeetingQueries.update_meeting(%{reschedule_requested_at: requested_at})

        assert :ok =
                 perform_job(EmailWorker, %{
                   "action" => "send_reschedule_request",
                   "meeting_id" => meeting.id
                 })
      end

      first_request = DateTime.add(DateTime.utc_now(:second), -600)
      request.(first_request)
      request.(first_request)

      assert [_one] = seat_jobs("send_seat_reschedule_request", first_id)

      request.(DateTime.utc_now(:second))

      assert "send_seat_reschedule_request"
             |> seat_jobs(first_id)
             |> Enum.map(& &1.args["requested_at"])
             |> Enum.uniq()
             |> length() == 2
    end
  end

  describe "a seat job sent to two recipients" do
    # The organiser's leg went out and the participant's failed: the job used
    # to be discarded as a partial send, so the participant never received
    # their confirmation or their seat links.
    test "retries only the participant after the organiser's copy went out",
         %{meeting_params: meeting_params} do
      meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
      first_id = participant_id!(meeting.id, "first@example.com")

      args = %{
        "action" => "send_seat_confirmation_emails",
        "meeting_id" => meeting.id,
        "participant_id" => first_id
      }

      expect(EmailServiceMock, :send_seat_update_to_organizer, 1, fn :booked, _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
        {:error, "SMTP unavailable"}
      end)

      assert {:error, _reason} = perform_job(EmailWorker, args)

      assert {:ok, participant} = ParticipantQueries.get(first_id)
      assert %DateTime{} = participant.organizer_notified_at
      assert participant.confirmation_sent_at == nil

      # The organiser is not expected again: a second call would fail the
      # Mox expectation above.
      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn email, _details ->
        assert email == "first@example.com"
        {:ok, "sent"}
      end)

      assert :ok = perform_job(EmailWorker, args)

      assert {:ok, %{confirmation_sent_at: %DateTime{}}} = ParticipantQueries.get(first_id)

      # Both legs recorded: a further run sends nothing at all.
      assert :ok = perform_job(EmailWorker, args)
    end
  end

  describe "seat jobs re-check the seat when they run" do
    test "a seat confirmation still queued when the organiser cancels the meeting sends nothing",
         %{meeting_params: meeting_params} do
      meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
      first_id = participant_id!(meeting.id, "first@example.com")

      assert {:ok, %{status: "cancelled"}} = Cancel.execute(meeting, caller: :organizer)

      # No mock expectation: any send would fail on the unexpected call.
      assert {:discard, _reason} =
               SeatEmails.handle_seat_confirmation_emails(%{
                 "meeting_id" => meeting.id,
                 "participant_id" => first_id
               })
    end

    test "a video room finishing after the meeting was cancelled releases no confirmations",
         %{meeting_params: meeting_params} do
      meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
      first_id = participant_id!(meeting.id, "first@example.com")
      Repo.delete_all(Oban.Job)

      assert {:ok, cancelled} =
               MeetingQueries.update_meeting_status(meeting, %{status: "cancelled"})

      assert :ok = Events.announce_video_room_outcome(cancelled)

      assert seat_jobs("send_seat_confirmation_emails", first_id) == []
    end

    test "a seat's own cancellation is sent only once the seat is actually cancelled",
         %{meeting_params: meeting_params} do
      meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
      first_id = participant_id!(meeting.id, "first@example.com")

      assert {:discard, _reason} =
               SeatEmails.handle_seat_cancellation_emails(
                 %{
                   "meeting_id" => meeting.id,
                   "participant_id" => first_id,
                   "slot_freed" => false
                 },
                 nil
               )
    end
  end

  describe "each seat is its own calendar entry" do
    test "seats get their own UIDs, a re-booked seat a new one, and a cancellation one revision up",
         %{meeting_params: meeting_params} do
      meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
      first = Enum.find(ParticipantQueries.list_live_for_meeting(meeting.id), & &1)
      _joined = book_seat!(meeting_params, "Second Booker", "second@example.com")
      second_id = participant_id!(meeting.id, "second@example.com")
      test_pid = self()

      stub(EmailServiceMock, :send_seat_update_to_organizer, fn _variant, _email, _details ->
        {:ok, "sent"}
      end)

      stub(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn email, details ->
        send(test_pid, {:confirmation, email, details})
        {:ok, "sent"}
      end)

      for id <- [first.id, second_id] do
        assert :ok =
                 perform_job(EmailWorker, %{
                   "action" => "send_seat_confirmation_emails",
                   "meeting_id" => meeting.id,
                   "participant_id" => id
                 })
      end

      assert_received {:confirmation, "first@example.com", first_details}
      assert_received {:confirmation, "second@example.com", second_details}

      assert first_details.uid == first.id
      assert second_details.uid == second_id
      refute first_details.uid == meeting.calendar_uid

      first_invite =
        ics(AppointmentConfirmation.render(:attendee, "first@example.com", first_details))

      assert first_invite =~ "UID:#{first.id}@"
      assert first_invite =~ "SEQUENCE:0"

      assert {:ok, :seat_cancelled} = CancelSeat.execute(first.management_token)
      assert {:ok, %{ical_sequence: 1}} = ParticipantQueries.get(first.id)

      expect(EmailServiceMock, :send_cancellation_email_to_attendee, fn email, details ->
        send(test_pid, {:cancellation, email, details})
        {:ok, "sent"}
      end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_seat_cancellation_emails",
                 "meeting_id" => meeting.id,
                 "participant_id" => first.id,
                 "slot_freed" => false
               })

      assert_received {:cancellation, "first@example.com", cancel_details}

      cancellation =
        ics(AppointmentCancellation.render(:attendee, "first@example.com", cancel_details))

      assert cancellation =~ "UID:#{first.id}@"
      assert cancellation =~ "SEQUENCE:1"
      assert cancellation =~ "STATUS:CANCELLED"

      rebooked = book_seat!(meeting_params, "First Booker", "first@example.com")
      rebooked_id = participant_id!(rebooked.id, "first@example.com")
      refute rebooked_id == first.id
    end
  end

  # The last seat leaving cancels the meeting. The organiser used to get a
  # meeting-level "The appointment with  has been cancelled", naming nobody;
  # now they get exactly one email, the leaver's, saying the slot is free.
  describe "the last seat leaving" do
    test "sends the organiser one email naming the leaver and saying the slot is free",
         %{meeting_params: meeting_params} do
      meeting = book_seat!(meeting_params, "Solo Booker", "solo@example.com")
      [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)

      assert {:ok, :meeting_cancelled} = CancelSeat.execute(participant.management_token)

      seat_args = %{
        "action" => "send_seat_cancellation_emails",
        "meeting_id" => meeting.id,
        "participant_id" => participant.id,
        "slot_freed" => true
      }

      assert_enqueued(worker: EmailWorker, args: seat_args)

      # The emptied meeting's own cancellation sends the organiser nothing:
      # no expectation is set, so any send would fail on the unexpected call.
      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => meeting.id
               })

      test_pid = self()

      stub(EmailServiceMock, :send_cancellation_email_to_attendee, fn _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_seat_update_to_organizer, fn :cancelled, email, details ->
        send(test_pid, {:organizer, email, details})
        {:ok, "sent"}
      end)

      assert :ok = perform_job(EmailWorker, seat_args)

      assert_received {:organizer, "organizer@example.com", details}
      assert details.attendee_name == "Solo Booker"
      assert details.slot_freed == true

      email =
        SeatUpdateForOrganizer.render(:cancelled, "organizer@example.com", %{
          details
          | organizer_locale: "en"
        })

      assert email.subject =~ "Slot freed: Solo Booker cancelled"

      assert email.text_body =~
               "Solo Booker cancelled their spot. Nobody is left on this slot, so the meeting has been cancelled and the time is free again."

      refute email.text_body =~ "The appointment with"
      refute email.text_body =~ "spots taken"
    end
  end

  defp ics(%Swoosh.Email{attachments: attachments}) do
    attachments
    |> Enum.find(&(&1.content_type == "text/calendar"))
    |> Map.fetch!(:data)
  end
end
