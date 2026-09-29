defmodule Tymeslot.Bookings.CalendarUidJourneyTest do
  @moduledoc """
  A booking's calendar identity from end to end.

  A meeting's `uid` is a bearer capability: the cancel and reschedule links
  are built from it, and whoever holds it can call the booking off. So it
  must never be what the organiser's calendar holds, where delegates,
  colleagues on a shared calendar and any syncing tool can read it. The
  booking's event is keyed by `calendar_uid` instead.

  The journey here is the one a guest takes: book, receive the confirmation,
  cancel from the link in it. Every write the calendar provider sees along the
  way must carry the calendar uid, and the link must still carry the uid.
  Meetings booked before the column existed were given `calendar_uid = uid`,
  so their events, already written under the uid, must keep matching.
  """

  # Not async: the real email service delivers from the circuit breaker's
  # process, which reaches this one only through the shared Swoosh setting.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.UUID
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.CalendarEventSync
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks

  @timezone "Europe/London"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()

    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    %{user: user} = create_always_bookable_profile()
    integration = insert(:calendar_integration, user: user, provider: "caldav")
    meeting_type = insert(:meeting_type, user: user, duration_minutes: 30, is_active: true)

    stub_calendar_writes(integration)

    %{user: user, integration: integration, meeting_type: meeting_type}
  end

  describe "a new booking" do
    test "is written, emailed and cancelled under its calendar uid, and cancelled by its uid",
         %{user: user, meeting_type: meeting_type} do
      meeting = book(user, meeting_type)
      refute meeting.calendar_uid == meeting.uid

      # The provider is sent the calendar uid, and nothing derived from the uid.
      assert %{success: 1, failure: 0} = drain_calendar_jobs()
      assert_received {:calendar_create, created}
      assert created.uid == meeting.calendar_uid
      refute leaks_uid?(created, meeting)

      # The confirmation's calendar file names the same event as the
      # organiser's calendar; the cancel link is the only place the uid goes.
      assert %{success: success, failure: 0} = Oban.drain_queue(queue: :emails)
      assert success >= 1
      attendee_email = received_email_to(meeting.attendee_email)
      ics = calendar_attachment(attendee_email)

      assert ics.data =~ "UID:#{meeting.calendar_uid}@"
      refute leaks_uid?(ics.data, meeting)
      refute leaks_uid?(ics.filename, meeting)
      assert attendee_email.html_body =~ "/meeting/#{meeting.uid}/cancel"

      # The guest cancels from that link; the organiser's event is deleted by
      # the calendar uid.
      assert link_uid(attendee_email.html_body) == meeting.uid
      assert {:ok, _cancelled} = Cancel.execute(link_uid(attendee_email.html_body))

      assert %{success: 1, failure: 0} = drain_calendar_jobs()
      assert_received {:calendar_delete, deleted_identifier}
      assert deleted_identifier == meeting.calendar_uid
      refute_received {:calendar_delete, _another}
    end

    test "is recognised as the organiser's own event when its mirror is read back",
         %{user: user, meeting_type: meeting_type} do
      meeting = book(user, meeting_type)

      mirror = %{
        uid: meeting.calendar_uid,
        provider_event_id: "/cal/primary/#{meeting.calendar_uid}.ics",
        start_time: meeting.start_time,
        end_time: meeting.end_time
      }

      periods =
        Meetings.merge_busy_periods(
          [mirror],
          user.id,
          DateTime.add(meeting.start_time, -1, :day),
          DateTime.add(meeting.end_time, 1, :day)
        )

      # The mirror is dropped for the booking it copies: one period, not two.
      assert [period] = periods
      assert period.uid == meeting.calendar_uid
      refute period.provider_event_id == mirror.provider_event_id
    end
  end

  describe "a meeting booked before calendar uids existed" do
    # The migration gave such a meeting `calendar_uid = uid`: its event was
    # written under the uid, and has to stay reachable.
    setup %{user: user, integration: integration} do
      uid = UUID.generate()

      meeting =
        insert(:meeting,
          uid: uid,
          calendar_uid: uid,
          organizer_user_id: user.id,
          calendar_integration_id: integration.id,
          calendar_path: "primary",
          provider_event_id: nil
        )

      %{meeting: meeting}
    end

    test "has its event updated and then deleted under the value it was written with",
         %{meeting: meeting} do
      assert :ok = CalendarEventSync.update(meeting.id, 1)
      assert_received {:calendar_update, updated_identifier, event_data}
      assert updated_identifier == meeting.uid
      assert event_data.uid == meeting.uid

      {:ok, cancelled} = MeetingQueries.update_meeting(meeting, %{status: "cancelled"})
      assert :ok = CalendarEventSync.delete(cancelled.id, 1)
      assert_received {:calendar_delete, deleted_identifier}
      assert deleted_identifier == meeting.uid
    end

    test "is still found by inbound sync from its event", %{meeting: meeting} do
      assert {:ok, found} =
               Sync.find_meeting(
                 meeting.calendar_integration_id,
                 "/cal/some-href.ics",
                 meeting.uid
               )

      assert found.id == meeting.id
    end
  end

  # CalDAV-shaped: the server confirms the UID it was given.
  defp stub_calendar_writes(integration) do
    test = self()

    Tymeslot.CalendarMock
    |> stub(:get_booking_integration_info, fn _context ->
      {:ok, %{integration_id: integration.id, calendar_path: "primary"}}
    end)
    |> stub(:create_event, fn event_data, _context ->
      send(test, {:calendar_create, event_data})
      {:ok, CreatedEvent.new(event_data.uid)}
    end)
    |> stub(:update_event, fn identifier, event_data, _context ->
      send(test, {:calendar_update, identifier, event_data})
      :ok
    end)
    |> stub(:delete_event, fn identifier, _context ->
      send(test, {:calendar_delete, identifier})
      :ok
    end)
  end

  defp book(user, meeting_type) do
    start_time = booking_start()
    local = DateTime.shift_zone!(start_time, @timezone)

    params = %{
      form_data: %{"name" => "Ada Lovelace", "email" => "ada@example.com"},
      meeting_params: %{
        date: Date.to_iso8601(DateTime.to_date(local)),
        time: Calendar.strftime(local, "%H:%M"),
        duration: "30min",
        user_timezone: @timezone,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      }
    }

    assert {:ok, meeting} = Orchestrator.submit_booking(params, organizer_user_id: user.id)
    meeting
  end

  # A whole hour three days out, which the open schedule always offers.
  defp booking_start do
    %{
      DateTime.add(DateTime.utc_now(), 3, :day)
      | hour: 13,
        minute: 0,
        second: 0,
        microsecond: {0, 0}
    }
  end

  defp drain_calendar_jobs, do: Oban.drain_queue(queue: :calendar_events)

  defp received_email_to(address) do
    assert_received {:email, %Swoosh.Email{to: [{_name, ^address}]} = email}
    email
  end

  defp calendar_attachment(email) do
    assert [ics] = Enum.filter(email.attachments, &String.ends_with?(&1.filename, ".ics"))
    ics
  end

  defp link_uid(html) do
    [uid] = Regex.run(~r"/meeting/([0-9a-f-]{36})/cancel", html, capture: :all_but_first)
    uid
  end

  # Both spellings of the UUID, since a Google event id is the uid with its
  # hyphens stripped.
  defp leaks_uid?(payload, meeting) do
    text = if is_binary(payload), do: payload, else: inspect(payload, limit: :infinity)

    String.contains?(text, meeting.uid) or
      String.contains?(text, String.replace(meeting.uid, "-", ""))
  end
end
