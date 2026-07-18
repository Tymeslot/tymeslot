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

  test "reminder job sends one reminder per live participant plus one organiser reminder",
       %{meeting_params: meeting_params} do
    meeting = book_seat!(meeting_params, "First Booker", "first@example.com")
    _same = book_seat!(meeting_params, "Second Booker", "second@example.com")

    expect(EmailServiceMock, :send_appointment_reminder_to_organizer, fn organizer_email,
                                                                         details ->
      assert organizer_email == "organizer@example.com"
      assert details.attendee_name == "2 participants"
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_appointment_reminder_to_attendee, 2, fn attendee_email,
                                                                           details ->
      assert attendee_email in ["first@example.com", "second@example.com"]
      assert details.attendee_name in ["First Booker", "Second Booker"]
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_reminder_emails",
               "meeting_id" => meeting.id,
               "reminder_value" => 30,
               "reminder_unit" => "minutes"
             })
  end
end
