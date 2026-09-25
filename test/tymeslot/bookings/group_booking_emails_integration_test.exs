defmodule Tymeslot.Bookings.GroupBookingEmailsIntegrationTest do
  @moduledoc """
  Integration coverage for the group-booking seat flow:
  seat booked -> per-seat email job -> emails delivered -> calendar update job.

  Delivery is asserted through `Tymeslot.EmailServiceMock` (Mox) rather than
  `Swoosh.TestAssertions`. `Tymeslot.Emails.Delivery.deliver/1` wraps every
  send in `Tymeslot.Infrastructure.CircuitBreaker.call/2`, which runs the
  delivery function inside its own GenServer — so the `{:email, ...}`
  message Swoosh's test adapter posts never reaches the test process (the
  same constraint documented in `Tymeslot.Emails.DeliveryTest` and
  `Tymeslot.Emails.EmailServiceAdminAlertTest`). Mocking at the
  `Config.email_service_module/0` boundary still drives the full booking ->
  job -> handler flow end to end and lets us assert the per-seat isolation
  on the arguments handed to the mock.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.Factory

  alias Tymeslot.Bookings.CancelSeat
  alias Tymeslot.Bookings.Create
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.EmailWorkerHandlers.GroupMeetingEmails

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

  test "each seat enqueues its own confirmation job, and a seat's job delivers exactly one isolated participant email plus one organiser notification",
       %{meeting_params: meeting_params} do
    meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
    first_id = participant_id!(meeting.id, "first@example.com")

    _joined = book_seat!(meeting_params, "Second Booker", "second@example.com")
    second_id = participant_id!(meeting.id, "second@example.com")

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_seat_confirmation_emails",
        "meeting_id" => meeting.id,
        "participant_id" => first_id
      }
    )

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_seat_confirmation_emails",
        "meeting_id" => meeting.id,
        "participant_id" => second_id
      }
    )

    tokens_by_id =
      meeting.id
      |> ParticipantQueries.list_live_for_meeting()
      |> Map.new(&{&1.id, &1.management_token})

    # The organiser's copy is built from the bare meeting, not the booker's
    # own overlay — it must not carry the booker's identity or their
    # tokenised seat links (see
    # `GroupMeetingEmails.send_seat_confirmation_emails/2`).
    expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn organizer_email,
                                                                             details ->
      assert organizer_email == "organizer@example.com"
      refute details.attendee_name == "Second Booker"
      refute String.contains?(details.cancel_url || "", tokens_by_id[second_id])
      refute String.contains?(details.reschedule_url || "", tokens_by_id[second_id])
      refute inspect(details) =~ "first@example.com"
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn attendee_email,
                                                                            details ->
      assert attendee_email == "second@example.com"
      assert details.attendee_name == "Second Booker"
      assert String.contains?(details.cancel_url, tokens_by_id[second_id])
      refute inspect(details) =~ "first@example.com"
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_seat_confirmation_emails",
               "meeting_id" => meeting.id,
               "participant_id" => second_id
             })
  end

  test "the second seat schedules a calendar update job, not a create job",
       %{meeting_params: meeting_params} do
    meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
    _same = book_seat!(meeting_params, "Second Booker", "second@example.com")

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => meeting.id}
    )
  end

  test "reminder job dispatches one independently-retryable job per live participant, each delivering that participant's reminder, plus one organiser reminder sent inline",
       %{meeting_params: meeting_params} do
    meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
    first_id = participant_id!(meeting.id, "first@example.com")

    _same = book_seat!(meeting_params, "Second Booker", "second@example.com")
    second_id = participant_id!(meeting.id, "second@example.com")

    # Regression coverage for the enqueue path itself, not just the handler:
    # the first seat's booking is what schedules the meeting-level reminder
    # job. A group meeting has no meeting-row attendee, and the notification
    # layer used to reject it before this job was ever enqueued.
    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_reminder_emails",
        "meeting_id" => meeting.id,
        "reminder_value" => 30,
        "reminder_unit" => "minutes"
      }
    )

    expect(EmailServiceMock, :send_appointment_reminder_to_organizer, fn organizer_email,
                                                                         details ->
      assert organizer_email == "organizer@example.com"
      assert details.attendee_name == "2 participants"
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_reminder_emails",
               "meeting_id" => meeting.id,
               "reminder_value" => 30,
               "reminder_unit" => "minutes"
             })

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_seat_reminder",
        "meeting_id" => meeting.id,
        "participant_id" => first_id,
        "reminder_value" => 30,
        "reminder_unit" => "minutes"
      }
    )

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_seat_reminder",
        "meeting_id" => meeting.id,
        "participant_id" => second_id,
        "reminder_value" => 30,
        "reminder_unit" => "minutes"
      }
    )

    expect(EmailServiceMock, :send_appointment_reminder_to_attendee, fn attendee_email, details ->
      assert attendee_email == "first@example.com"
      assert details.attendee_name == "First Booker"
      refute inspect(details) =~ "second@example.com"
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_seat_reminder",
               "meeting_id" => meeting.id,
               "participant_id" => first_id,
               "reminder_value" => 30,
               "reminder_unit" => "minutes"
             })

    expect(EmailServiceMock, :send_appointment_reminder_to_attendee, fn attendee_email, details ->
      assert attendee_email == "second@example.com"
      assert details.attendee_name == "Second Booker"
      refute inspect(details) =~ "first@example.com"
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_seat_reminder",
               "meeting_id" => meeting.id,
               "participant_id" => second_id,
               "reminder_value" => 30,
               "reminder_unit" => "minutes"
             })
  end

  # The host asking to move a group meeting voids the slot for everybody on
  # it. The email went to `meeting.attendee_email`, which a group meeting does
  # not have, so every participant silently lost their spot instead.
  test "a reschedule request dispatches one independently-retryable job per live participant, each delivering with that participant's own seat links",
       %{meeting_params: meeting_params} do
    meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
    first_id = participant_id!(meeting.id, "first@example.com")

    _same = book_seat!(meeting_params, "Second Booker", "second@example.com")
    second_id = participant_id!(meeting.id, "second@example.com")

    tokens_by_id =
      meeting.id
      |> ParticipantQueries.list_live_for_meeting()
      |> Map.new(&{&1.id, &1.management_token})

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_reschedule_request",
               "meeting_id" => meeting.id
             })

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_seat_reschedule_request",
        "meeting_id" => meeting.id,
        "participant_id" => first_id
      }
    )

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_seat_reschedule_request",
        "meeting_id" => meeting.id,
        "participant_id" => second_id
      }
    )

    expect(EmailServiceMock, :send_reschedule_request, fn seat_meeting ->
      assert seat_meeting.attendee_email == "first@example.com"
      assert seat_meeting.attendee_name == "First Booker"
      # Their own seat link, not the whole meeting's.
      assert String.contains?(seat_meeting.reschedule_url, tokens_by_id[first_id])
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_seat_reschedule_request",
               "meeting_id" => meeting.id,
               "participant_id" => first_id
             })

    expect(EmailServiceMock, :send_reschedule_request, fn seat_meeting ->
      assert seat_meeting.attendee_email == "second@example.com"
      assert seat_meeting.attendee_name == "Second Booker"
      assert String.contains?(seat_meeting.reschedule_url, tokens_by_id[second_id])
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_seat_reschedule_request",
               "meeting_id" => meeting.id,
               "participant_id" => second_id
             })
  end

  # An emptied group meeting is still `group?/1` (capacity-based), so its
  # cancellation must fall through to the dedicated "organiser only" wording
  # rather than a fan-out over zero participants that would tell the
  # organiser "the appointment with 0 participants has been cancelled".
  test "the last seat leaving cancels the meeting and the organiser email carries no participant count",
       %{meeting_params: meeting_params} do
    meeting = book_seat!(meeting_params, "Solo Booker", "solo@example.com")
    [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)

    assert {:ok, :meeting_cancelled} = CancelSeat.execute(participant.management_token)

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_cancellation_emails", "meeting_id" => meeting.id}
    )

    expect(EmailServiceMock, :send_cancellation_email_to_organizer, fn organizer_email, details ->
      assert organizer_email == "organizer@example.com"
      assert details.attendee_name in [nil, ""]
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_cancellation_emails",
               "meeting_id" => meeting.id
             })
  end

  # `cancel_reminder_emails/1` only sweeps pending `send_reminder_emails`
  # jobs, not the `send_seat_reminder` jobs dispatched once that job runs —
  # so a seat cancelled after dispatch, or a meeting voided after dispatch,
  # must be caught by the handler itself.
  test "a seat reminder for a since-cancelled participant discards instead of emailing",
       %{meeting_params: meeting_params} do
    meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
    first = Enum.find(ParticipantQueries.list_live_for_meeting(meeting.id), & &1)

    _joined = book_seat!(meeting_params, "Second Booker", "second@example.com")

    assert {:ok, :seat_cancelled} = CancelSeat.execute(first.management_token)

    # No EmailServiceMock expectation is set: if the handler tried to send
    # anyway, this would crash on the unexpected Mox call rather than quietly
    # pass.
    assert {:discard, _reason} =
             GroupMeetingEmails.handle_seat_reminder_emails(%{
               "meeting_id" => meeting.id,
               "participant_id" => first.id,
               "reminder_value" => 30,
               "reminder_unit" => "minutes"
             })
  end

  test "a seat reminder for a voided meeting discards instead of emailing",
       %{meeting_params: meeting_params} do
    meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
    first = Enum.find(ParticipantQueries.list_live_for_meeting(meeting.id), & &1)

    assert {:ok, _cancelled} =
             MeetingQueries.update_meeting_status(meeting, %{status: "cancelled"})

    assert {:discard, _reason} =
             GroupMeetingEmails.handle_seat_reminder_emails(%{
               "meeting_id" => meeting.id,
               "participant_id" => first.id,
               "reminder_value" => 30,
               "reminder_unit" => "minutes"
             })
  end

  # `send_participant_guest_confirmations/4`'s body was previously
  # uncovered. A group booker's own guests must be confirmed the same way a
  # solo attendee's are.
  test "a group booker's guests are emailed when their seat is confirmed",
       %{meeting_params: meeting_params} do
    meeting =
      book_seat!(
        Map.put(meeting_params, :guest_emails, ["guest@example.com"]),
        "Booker With Guest",
        "hasguest@example.com"
      )

    participant_id = participant_id!(meeting.id, "hasguest@example.com")
    [guest] = GuestQueries.list_for_participant(participant_id)
    refute guest.confirmation_sent_at

    stub(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, _details ->
      {:ok, "sent"}
    end)

    stub(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_guest_confirmation, fn guest_email, _details ->
      assert guest_email == "guest@example.com"
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_seat_confirmation_emails",
               "meeting_id" => meeting.id,
               "participant_id" => participant_id
             })

    assert GuestQueries.get_by_token(guest.rsvp_token)
           |> elem(1)
           |> Map.get(:confirmation_sent_at)
  end

  # `send_seat_reschedule_emails/3` previously sent the mover's own
  # confirmation and the organiser's, but never touched guests — a mover's
  # guests re-booked at the new slot (fresh, unsent rows) would keep
  # whatever confirmation they had for the old, now-voided slot and never
  # learn where the meeting moved to.
  test "a seat reschedule also re-sends the mover's still-unsent guests",
       %{meeting_params: meeting_params} do
    meeting =
      book_seat!(
        Map.put(meeting_params, :guest_emails, ["guest@example.com"]),
        "Booker With Guest",
        "hasguest@example.com"
      )

    participant_id = participant_id!(meeting.id, "hasguest@example.com")
    [guest] = GuestQueries.list_for_participant(participant_id)
    refute guest.confirmation_sent_at

    stub(EmailServiceMock, :send_seat_reschedule_to_participant, fn _email, _details, _old ->
      {:ok, "sent"}
    end)

    stub(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, _details ->
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_guest_confirmation, fn guest_email, _details ->
      assert guest_email == "guest@example.com"
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_seat_reschedule_emails",
               "meeting_id" => meeting.id,
               "participant_id" => participant_id,
               "old_uid" => meeting.uid,
               "old_ical_sequence" => 0,
               "old_start_time" => DateTime.to_iso8601(meeting.start_time),
               "old_end_time" => DateTime.to_iso8601(meeting.end_time)
             })

    assert GuestQueries.get_by_token(guest.rsvp_token)
           |> elem(1)
           |> Map.get(:confirmation_sent_at)
  end

  # A provider outage (:circuit_open) previously got flattened into a plain
  # string by the per-seat handlers, losing the snooze semantics
  # `EmailWorker` relies on to ride out the breaker's recovery window instead
  # of burning ordinary retries on a provider it already knows is down.
  test "a circuit-open failure on a seat email is preserved, not flattened to a string",
       %{meeting_params: meeting_params} do
    meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
    first_id = participant_id!(meeting.id, "first@example.com")

    expect(EmailServiceMock, :send_cancellation_email_to_attendee, fn _email, _details ->
      {:error, :circuit_open}
    end)

    # `EmailWorker` translates the preserved `:circuit_open` reason into a
    # snooze past the breaker's recovery window (~300s) rather than an
    # ordinary retry — the whole point of not flattening it to a string.
    assert {:snooze, snooze_seconds} =
             perform_job(EmailWorker, %{
               "action" => "send_seat_meeting_cancellation",
               "meeting_id" => meeting.id,
               "participant_id" => first_id
             })

    assert snooze_seconds >= 300
  end
end
