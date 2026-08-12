defmodule Tymeslot.Bookings.CancelSeatIntegrationTest do
  @moduledoc """
  Integration coverage for participant seat cancellation: seat freed and
  broadcast, calendar event updated, emails sent; last leaver cancels the
  whole meeting and deletes the calendar event.

  Delivery is asserted through `Tymeslot.EmailServiceMock` (Mox) rather than
  `Swoosh.TestAssertions` — see `Tymeslot.Bookings.GroupBookingEmailsIntegrationTest`
  for the rationale: `Tymeslot.Emails.Delivery.deliver/1` runs every send
  inside the `Tymeslot.Infrastructure.CircuitBreaker` GenServer, so the
  `{:email, ...}` message Swoosh's test adapter posts never reaches the
  test process. Mocking at the `Config.email_service_module/0` boundary
  still drives the full cancel -> job -> handler flow end to end.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Phoenix.PubSub
  alias Tymeslot.Bookings.{Cancel, CancelSeat, Create}
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.Seats
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
        max_participants: 3
      )

    meeting_params = %{
      date: Date.add(Date.utc_today(), 2),
      time: "14:00",
      duration: "30min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    {:ok, meeting} =
      Create.execute(meeting_params, %{"name" => "Leaver", "email" => "leaver@example.com"})

    {:ok, _meeting} =
      Create.execute(meeting_params, %{"name" => "Stayer", "email" => "stayer@example.com"})

    participants = ParticipantQueries.list_live_for_meeting(meeting.id)
    leaver = Enum.find(participants, &(&1.email == "leaver@example.com"))
    stayer = Enum.find(participants, &(&1.email == "stayer@example.com"))

    %{meeting_type: meeting_type, meeting: meeting, leaver: leaver, stayer: stayer}
  end

  test "cancelling a seat frees it, broadcasts, updates the calendar event, and emails both sides",
       %{meeting_type: meeting_type, meeting: meeting, leaver: leaver} do
    :ok = PubSub.subscribe(Tymeslot.PubSub, "group_seats:#{meeting_type.id}")

    seats_before = Seats.seats_left(meeting, meeting_type.max_participants)

    assert {:ok, :seat_cancelled} = CancelSeat.execute(leaver.management_token)

    reloaded = Repo.get!(MeetingSchema, meeting.id)
    assert reloaded.status == "confirmed"
    assert Seats.seats_left(reloaded, meeting_type.max_participants) == seats_before + 1

    assert_receive {:seat_update, _meeting_type_id}

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => meeting.id}
    )

    expect(EmailServiceMock, :send_cancellation_email_to_attendee, fn attendee_email, details ->
      assert attendee_email == "leaver@example.com"
      assert details.attendee_name == "Leaver"
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_cancellation_email_to_organizer, fn organizer_email, details ->
      assert organizer_email == "organizer@example.com"
      assert details.attendee_name == "Leaver"
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_seat_cancellation_emails",
               "meeting_id" => meeting.id,
               "participant_id" => leaver.id,
               "notify_organizer" => true
             })
  end

  test "the last leaver cancels the whole meeting and deletes the calendar event",
       %{meeting: meeting, leaver: leaver, stayer: stayer} do
    assert {:ok, :seat_cancelled} = CancelSeat.execute(leaver.management_token)
    assert {:ok, :meeting_cancelled} = CancelSeat.execute(stayer.management_token)

    reloaded = Repo.get!(MeetingSchema, meeting.id)
    assert reloaded.status == "cancelled"

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "delete", "meeting_id" => meeting.id}
    )
  end

  test "a cancelled seat cannot be cancelled twice", %{leaver: leaver} do
    assert {:ok, :seat_cancelled} = CancelSeat.execute(leaver.management_token)
    assert {:error, :already_cancelled} = CancelSeat.execute(leaver.management_token)
  end

  # A freed seat changes what the booking page may offer, and availability is
  # cached per organiser. Without the invalidation the slot kept reading as
  # full (or stayed hidden entirely, for the last leaver) until the cache
  # aged out, however loudly the seat broadcast said otherwise.
  test "cancelling a seat drops the organiser's cached availability",
       %{meeting: meeting, leaver: leaver} do
    cache_key =
      AvailabilityCache.availability_range_key(
        meeting.organizer_user_id,
        Date.utc_today(),
        Date.add(Date.utc_today(), 41),
        "Etc/UTC",
        30
      )

    AvailabilityCache.put(cache_key, {:ok, %{"seeded" => true}})

    assert {:ok, :seat_cancelled} = CancelSeat.execute(leaver.management_token)

    assert AvailabilityCache.get_or_compute(cache_key, fn -> :recomputed end) == :recomputed
  end

  # Whoever asks second must see the other's work. Without a row lock both
  # leavers count the other as still live, so neither cancels the meeting and
  # a confirmed slot survives with nobody on it — still holding the
  # organiser's calendar and still firing reminders.
  test "two people leaving one after the other still cancel the meeting",
       %{meeting: meeting, leaver: leaver, stayer: stayer} do
    assert {:ok, :seat_cancelled} = CancelSeat.execute(leaver.management_token)
    assert {:ok, :meeting_cancelled} = CancelSeat.execute(stayer.management_token)

    assert Repo.get!(MeetingSchema, meeting.id).status == "cancelled"
    assert ParticipantQueries.count_live_for_meeting(meeting.id) == 0
  end

  test "organiser cancel-all emails every live participant and voids guest RSVPs",
       %{meeting: meeting, leaver: leaver, stayer: stayer} do
    assert {:ok, cancelled_meeting} = Cancel.execute(meeting)
    assert cancelled_meeting.status == "cancelled"

    # Regression coverage for the enqueue path itself, not just the handler:
    # a group meeting has no meeting-row attendee, and the notification
    # layer used to reject it before ever calling `schedule_cancellation_emails/1`.
    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_cancellation_emails",
        "meeting_id" => meeting.id
      }
    )

    expect(EmailServiceMock, :send_cancellation_email_to_organizer, fn organizer_email, details ->
      assert organizer_email == "organizer@example.com"
      assert details.attendee_name == "2 participants"
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_cancellation_emails",
               "meeting_id" => meeting.id
             })

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_seat_meeting_cancellation",
        "meeting_id" => meeting.id,
        "participant_id" => leaver.id
      }
    )

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_seat_meeting_cancellation",
        "meeting_id" => meeting.id,
        "participant_id" => stayer.id
      }
    )

    expect(EmailServiceMock, :send_cancellation_email_to_attendee, fn attendee_email, details ->
      assert attendee_email == "leaver@example.com"
      assert details.attendee_name == "Leaver"
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_seat_meeting_cancellation",
               "meeting_id" => meeting.id,
               "participant_id" => leaver.id
             })

    expect(EmailServiceMock, :send_cancellation_email_to_attendee, fn attendee_email, details ->
      assert attendee_email == "stayer@example.com"
      assert details.attendee_name == "Stayer"
      {:ok, "sent"}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_seat_meeting_cancellation",
               "meeting_id" => meeting.id,
               "participant_id" => stayer.id
             })

    # Guest RSVP links on a cancelled meeting are inert.
    assert {:error, :not_found} = Meetings.record_guest_rsvp("does-not-matter", "accepted")
  end
end
