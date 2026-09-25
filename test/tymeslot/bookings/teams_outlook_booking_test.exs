defmodule Tymeslot.Bookings.TeamsOutlookBookingTest do
  @moduledoc """
  A booking whose Outlook calendar and Microsoft Teams integration are the
  same Microsoft account, from the public booking through both jobs it sets
  off: the calendar job that writes the booking's Outlook event, and the video
  job that makes the Teams meeting.

  A Teams meeting is itself an Outlook event, so the meeting belongs on the
  booking's own event; a second event carrying it is the duplicate #145
  reported. The two jobs run on separate queues and either can go first, so
  both orders are walked here, through the real Outlook calendar client and
  Teams provider with only Microsoft Graph (HTTP) mocked.
  """

  # Not async: the calendar module is swapped application-wide for the real
  # runtime one, and room creation runs through the application-wide Teams
  # circuit breaker.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.{CalendarEventWorker, VideoRoomWorker}

  setup :verify_on_exit!

  @account_id "entra-oid-organiser"
  @calendar_id "AAMk-calendar"
  @booking_event "AAMk-booking-event"
  @graph "https://graph.microsoft.com/v1.0"

  setup do
    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    %{user: user} = create_always_bookable_profile()

    insert(:calendar_integration,
      user: user,
      provider: "outlook",
      provider_account_id: @account_id,
      oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite offline_access",
      access_token_encrypted: Encryption.encrypt("graph-access-token"),
      refresh_token_encrypted: Encryption.encrypt("graph-refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      default_booking_calendar_id: @calendar_id
    )

    teams =
      insert(:video_integration,
        user: user,
        name: "Teams",
        provider: "teams",
        base_url: nil,
        api_key_encrypted: nil,
        access_token_encrypted: Encryption.encrypt("graph-access-token"),
        refresh_token_encrypted: Encryption.encrypt("graph-refresh-token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite offline_access",
        provider_account_id: @account_id
      )

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Teams Consultation",
        duration_minutes: 30,
        is_active: true,
        allow_video: true,
        video_integration_id: teams.id
      )

    stub(Tymeslot.TeamsOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    %{user: user, meeting: book(user, meeting_type)}
  end

  test "calendar job first: the meeting is switched on for the booking's event", %{
    meeting: meeting
  } do
    use_runtime_calendar()
    report_graph_requests()

    run_calendar_jobs()
    assert :ok = run_video_job(meeting)
    run_calendar_jobs()

    assert_one_event_carrying_the_meeting(meeting)
  end

  test "video job first: it waits for the booking's event rather than writing its own", %{
    meeting: meeting
  } do
    use_runtime_calendar()
    report_graph_requests()

    assert :ok = run_video_job(meeting)
    assert graph_requests() == []

    run_calendar_jobs()
    assert :ok = run_video_job(meeting)
    run_calendar_jobs()

    assert_one_event_carrying_the_meeting(meeting)
  end

  defp assert_one_event_carrying_the_meeting(meeting) do
    requests = graph_requests()

    # One event in the organiser's calendar: the booking's, written by the
    # calendar job. A POST to /me/events would be the Teams meeting's own.
    assert [{:post, post_url, _created}] = for({:post, _url, _body} = req <- requests, do: req)
    assert post_url == "#{@graph}/me/calendars/#{@calendar_id}/events"

    # The Teams meeting is switched on for that very event, and only once.
    assert [online_meeting] =
             for(
               {:patch, url, body} <- requests,
               url == "#{@graph}/me/events/#{@booking_event}",
               do: body
             )

    assert online_meeting["isOnlineMeeting"] == true
    refute Enum.any?(requests, &match?({:delete, _url, _body}, &1))

    updated = Repo.get!(MeetingSchema, meeting.id)
    assert updated.provider_event_id == @booking_event
    assert updated.video_room_id == @booking_event
    assert updated.meeting_url == join_url()
    assert updated.uid == meeting.uid
  end

  defp book(user, meeting_type) do
    params = %{
      form_data: %{"name" => "Ada Attendee", "email" => "ada@example.com", "message" => ""},
      meeting_params: %{
        date: Date.add(Date.utc_today(), 2),
        time: "14:00",
        duration: "30min",
        user_timezone: "Europe/London",
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        with_video_room: true
      }
    }

    assert {:ok, booked} = Orchestrator.submit_booking(params, organizer_user_id: user.id)

    assert_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => booked.id})

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"meeting_id" => booked.id, "action" => "create"}
    )

    booked
  end

  defp run_video_job(meeting),
    do: perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id, "announce" => true})

  defp run_calendar_jobs do
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :calendar_events)
  end

  # Graph answers every request, reporting it to the test. A created event is
  # the booking's; any other write addresses an existing event by the id at
  # the end of its path, and carries the Teams meeting once it is switched on.
  defp report_graph_requests do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      sent = if is_binary(body) and body != "", do: Jason.decode!(body), else: %{}
      send(test_pid, {:graph, method, url, sent})

      id = if method == :post, do: @booking_event, else: url |> String.split("/") |> List.last()

      {:ok,
       %Req.Response{
         status: if(method == :post, do: 201, else: 200),
         body:
           sent
           |> Map.merge(%{"id" => id, "iCalUId" => "ical-#{id}"})
           |> Map.merge(online_meeting(sent))
           |> Jason.encode!()
       }}
    end)
  end

  defp online_meeting(%{"isOnlineMeeting" => true}),
    do: %{"onlineMeeting" => %{"joinUrl" => join_url()}}

  defp online_meeting(_sent), do: %{}

  defp join_url, do: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_booking"

  defp graph_requests do
    receive do
      {:graph, method, url, body} -> [{method, url, body} | graph_requests()]
    after
      0 -> []
    end
  end

  defp use_runtime_calendar do
    calendar_module = Application.get_env(:tymeslot, :calendar_module)
    outlook_api = Application.get_env(:tymeslot, :outlook_calendar_api_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)
    Application.put_env(:tymeslot, :outlook_calendar_api_module, CalendarAPI)

    on_exit(fn ->
      Application.put_env(:tymeslot, :calendar_module, calendar_module)
      Application.put_env(:tymeslot, :outlook_calendar_api_module, outlook_api)
    end)
  end
end
