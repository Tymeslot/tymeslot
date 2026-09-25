defmodule Tymeslot.Bookings.FlaggedCalendarFallbackTest do
  @moduledoc """
  The journey behind a calendar whose credentials the provider refused: the
  token refresh job leaves it active and flags it for reconnection, and every
  booking the host takes from then on has to land in their other calendar.

  Before the resolver looked past `is_active`, the flagged integration stayed
  the booking target, the calendar event job failed against it on every
  attempt of every booking, and the host was alerted once per booking while
  a working calendar sat unused. The two cases cover the two ways a booking
  meets a flagged calendar: a new booking against a meeting type that names
  it, and a booking recorded before the flag went up whose event is written
  afterwards.

  Everything between the booking and the SOAP body is real: the resolver,
  the provider adapter, the request builder. Only the HTTP boundary is
  stubbed, and the calendar seam is pointed back at the real implementation
  for the two calls that decide the target.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :calendar
  @moduletag :workers
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.ExchangeCase
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker

  @healthy_url "https://mail.example.com/EWS/Exchange.asmx"
  @healthy_folder "AAAAAHWP+wXiGGhNkiDQ+d65ZYgBAAEAAAA="
  @item_id "AAAAAHWP+wXiGGhNkiDQ+d65ZYgHAAEAAAM="

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false
    )

    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    ExchangeCase.reset_breaker(@healthy_url)

    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    # The suite-wide calendar double is right for the availability reads the
    # booking path makes; the two calls that pick the calendar a booking is
    # written to must run for real, or the test would only be checking the
    # double.
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn context ->
      Operations.get_booking_integration_info(context)
    end)

    stub(Tymeslot.CalendarMock, :create_event, fn event_data, context ->
      Operations.create_event(event_data, context)
    end)

    user = insert(:user, email: "host@example.com", name: "Host")

    healthy =
      insert(:calendar_integration,
        user: user,
        provider: "exchange",
        base_url: @healthy_url,
        username_encrypted: Encryption.encrypt("host@example.com"),
        password_encrypted: Encryption.encrypt("secret"),
        provider_account_email: "host@example.com",
        default_booking_calendar_id: @healthy_folder,
        calendar_list: [
          %CalendarEntry{id: @healthy_folder, name: "Calendar", selected: true, read_only: false}
        ]
      )

    # What the token refresh job leaves behind once Google refuses the
    # refresh token: still active, flagged for reconnection.
    flagged =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        is_active: true,
        needs_reauth: true,
        default_booking_calendar_id: "primary"
      )

    profile =
      insert(:profile,
        user: user,
        timezone: "Europe/Berlin",
        primary_calendar_integration_id: healthy.id
      )

    _schedule = open_schedule_for(profile)

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Intro",
        duration_minutes: 30,
        is_active: true,
        calendar_integration_id: flagged.id,
        target_calendar_id: "primary"
      )

    %{user: user, healthy: healthy, flagged: flagged, meeting_type: meeting_type}
  end

  test "a new booking against a meeting type naming the flagged calendar is recorded against the working one",
       %{user: user, healthy: healthy, meeting_type: meeting_type} do
    params = %{
      form_data: %{"name" => "Attendee", "email" => "attendee@example.com", "message" => ""},
      meeting_params: %{
        date: Date.to_iso8601(next_bookable_weekday(5)),
        time: "14:00",
        duration: "30min",
        user_timezone: "Europe/Berlin",
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      }
    }

    assert {:ok, meeting} = Orchestrator.submit_booking(params)

    assert meeting.calendar_integration_id == healthy.id
    assert meeting.calendar_path == @healthy_folder

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "create", "meeting_id" => meeting.id}
    )
  end

  test "the calendar event job writes a booking recorded against the flagged calendar to the working one",
       %{user: user, healthy: healthy, flagged: flagged} do
    # Booked while the Google calendar still worked, so it recorded that
    # calendar; the flag went up before the event was written.
    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        calendar_integration_id: flagged.id,
        calendar_path: "primary",
        title: "Intro call",
        start_time: ~U[2026-10-05 09:00:00Z],
        end_time: ~U[2026-10-05 09:30:00Z]
      )

    capture_requests()

    assert :ok =
             perform_job(CalendarEventWorker, %{"action" => "create", "meeting_id" => meeting.id})

    assert_received {:ews_request, host, body}
    assert host == "mail.example.com"
    assert body =~ "<m:CreateItem"
    assert body =~ ~s(<t:FolderId Id="#{@healthy_folder}"/>)

    {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
    assert reloaded.calendar_integration_id == healthy.id
    assert reloaded.provider_event_id == @item_id
  end

  defp capture_requests do
    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      send(test_pid, {:ews_request, conn.host, body})

      conn
      |> Conn.put_resp_content_type("text/xml")
      |> Conn.resp(200, create_response())
    end)
  end

  defp create_response do
    ExchangeCase.response_envelope("CreateItem", """
    <m:Items>
      <t:CalendarItem><t:ItemId Id="#{@item_id}" ChangeKey="CK=="/></t:CalendarItem>
    </m:Items>
    """)
  end
end
