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
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Create
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.ParticipantQueries
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
        name: "Group Workshop",
        duration_minutes: 30,
        is_active: true,
        max_participants: 3
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

    expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn organizer_email,
                                                                             details ->
      assert organizer_email == "organizer@example.com"
      assert details.attendee_name == "Second Booker"
      assert details.attendee_email == "second@example.com"
      refute inspect(details) =~ "first@example.com"
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn attendee_email,
                                                                            details ->
      assert attendee_email == "second@example.com"
      assert details.attendee_name == "Second Booker"
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
end
