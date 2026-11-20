defmodule Tymeslot.Bookings.GoogleMeetBookingTest do
  @moduledoc """
  A booking whose Google Calendar and Google Meet integration are the same
  Google account, from the public booking through both jobs it sets off: the
  calendar job that writes the booking's Google event, and the video job that
  gives the booking its Meet link.

  Google Calendar replaces a Meet code made outside Calendar with one made for
  the event, so a standalone Meet space written into the event leaves the
  guest's link and the event's own Meet link pointing at different rooms. The
  booking's event is therefore created asking Google for a Meet, and the
  booking takes that Meet's link. The two jobs run on separate queues and
  either can go first, so both orders are walked here, through the real Google
  Calendar client with only HTTP mocked.
  """

  # Not async: the calendar module and the Google Calendar API module are
  # swapped application-wide for the real ones.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.{CalendarEventWorker, VideoRoomWorker}

  setup :verify_on_exit!

  @account_id "google-sub-organiser"
  @calendar_id "organiser@example.com"
  @meet_url "https://meet.google.com/abc-defg-hij"

  setup do
    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    %{user: user} = create_always_bookable_profile()

    insert(:calendar_integration,
      user: user,
      provider: "google",
      provider_account_id: @account_id,
      oauth_scope: "https://www.googleapis.com/auth/calendar",
      access_token_encrypted: Encryption.encrypt("google-access-token"),
      refresh_token_encrypted: Encryption.encrypt("google-refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      default_booking_calendar_id: @calendar_id
    )

    meet =
      insert(:video_integration,
        user: user,
        name: "Google Meet",
        provider: "google_meet",
        base_url: nil,
        api_key_encrypted: nil,
        access_token_encrypted: Encryption.encrypt("google-access-token"),
        refresh_token_encrypted: Encryption.encrypt("google-refresh-token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope:
          "https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/meetings.space.created",
        provider_account_id: @account_id
      )

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Meet Consultation",
        duration_minutes: 30,
        is_active: true,
        allow_video: true,
        video_integration_id: meet.id
      )

    %{user: user, meeting: book(user, meeting_type)}
  end

  test "calendar job first: the booking takes the Meet Google made on its event", %{
    meeting: meeting
  } do
    use_runtime_calendar()
    report_google_requests()

    run_calendar_jobs()
    assert :ok = run_video_job(meeting)
    run_calendar_jobs()

    assert_one_event_carrying_the_meet(meeting)
  end

  test "video job first: it waits for the booking's event rather than making a Meet of its own",
       %{meeting: meeting} do
    use_runtime_calendar()
    report_google_requests()

    assert :ok = run_video_job(meeting)
    assert google_requests() == []

    run_calendar_jobs()
    assert :ok = run_video_job(meeting)
    run_calendar_jobs()

    assert_one_event_carrying_the_meet(meeting)
  end

  defp assert_one_event_carrying_the_meet(meeting) do
    requests = google_requests()

    # A POST to the Meet API would be a standalone Meet space, the room that
    # Google Calendar later replaces with a second link.
    assert for({_method, %URI{host: "meet.googleapis.com"} = uri, _body} <- requests, do: uri) ==
             []

    # One write in all: the calendar job creating the booking's event, asking
    # Google for its Meet.
    assert [{:post, post_uri, created}] =
             for({method, _uri, _body} = req <- requests, method != :get, do: req)

    assert post_uri.path == "/calendar/v3/calendars/#{URI.encode_www_form(@calendar_id)}/events"
    assert URI.decode_query(post_uri.query)["conferenceDataVersion"] == "1"

    assert %{"createRequest" => %{"conferenceSolutionKey" => %{"type" => "hangoutsMeet"}}} =
             created["conferenceData"]

    assert ["ada@example.com"] = for(a <- created["attendees"], do: a["email"])

    updated = Repo.get!(MeetingSchema, meeting.id)
    assert updated.provider_event_id == created["id"]
    assert updated.video_room_id == created["id"]
    assert updated.meeting_url == @meet_url
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

  # Google answers every request, reporting it to the test, and keeps the
  # events it is given, so a read sees what the writes before it left. As
  # Google does, a create asking for a Meet (`conferenceDataVersion=1` with a
  # `createRequest`) is answered while the Meet is still being made, and the
  # Meet's link is there on the next read. A write without
  # `conferenceDataVersion=1` leaves the event's conference as it is, and
  # times come back with their offset in the event's time zone.
  defp report_google_requests do
    test_pid = self()
    {:ok, events} = Agent.start_link(fn -> %{} end)

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      uri = URI.parse(url)
      sent = if is_binary(body) and body != "", do: Jason.decode!(body), else: %{}
      send(test_pid, {:google, method, uri, sent})

      case {method, uri.host} do
        {:get, "www.googleapis.com"} -> read_event(events, uri)
        {_write, "www.googleapis.com"} -> write_event(events, method, uri, sent)
        _other -> {:ok, %Req.Response{status: 404, body: ~s({"error":{"message":"unexpected"}})}}
      end
    end)
  end

  defp read_event(events, uri) do
    id = uri.path |> String.split("/") |> List.last()

    case Agent.get(events, &Map.get(&1, id)) do
      nil -> {:ok, %Req.Response{status: 404, body: ~s({"error":{"message":"Not Found"}})}}
      event -> {:ok, %Req.Response{status: 200, body: Jason.encode!(made_meet(event))}}
    end
  end

  defp write_event(events, method, uri, sent) do
    id = if method == :post, do: sent["id"], else: uri.path |> String.split("/") |> List.last()
    with_conference? = URI.decode_query(uri.query || "")["conferenceDataVersion"] == "1"

    event =
      Agent.get_and_update(events, fn stored ->
        previous = Map.get(stored, id, %{})
        written = if with_conference?, do: sent, else: Map.delete(sent, "conferenceData")

        event =
          previous
          |> Map.merge(written)
          |> Map.merge(%{"id" => id, "iCalUID" => "#{id}@google.com", "status" => "confirmed"})
          |> keep_conference(previous, with_conference?)
          |> with_offsets()
          |> pending_meet()

        {event, Map.put(stored, id, event)}
      end)

    {:ok, %Req.Response{status: 200, body: Jason.encode!(event)}}
  end

  defp keep_conference(event, %{"conferenceData" => conference}, false),
    do: Map.put(event, "conferenceData", conference)

  defp keep_conference(event, _previous, _with_conference?), do: event

  defp with_offsets(event) do
    event
    |> Map.update("start", nil, &offset_time/1)
    |> Map.update("end", nil, &offset_time/1)
  end

  defp offset_time(%{"dateTime" => local, "timeZone" => zone} = time) do
    case DateTime.from_iso8601(local) do
      {:ok, _with_offset, _seconds} ->
        time

      {:error, :missing_offset} ->
        zoned = local |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!(zone)
        Map.put(time, "dateTime", DateTime.to_iso8601(zoned))
    end
  end

  defp offset_time(time), do: time

  defp pending_meet(%{"conferenceData" => %{"createRequest" => request}} = event)
       when not is_map_key(request, "status") do
    put_in(event, ["conferenceData", "createRequest", "status"], %{"statusCode" => "pending"})
  end

  defp pending_meet(event), do: event

  defp made_meet(%{"conferenceData" => %{"createRequest" => _request} = conference} = event) do
    made =
      conference
      |> put_in(["createRequest", "status"], %{"statusCode" => "success"})
      |> Map.put("entryPoints", [%{"entryPointType" => "video", "uri" => @meet_url}])

    event
    |> Map.put("conferenceData", made)
    |> Map.put("hangoutLink", @meet_url)
  end

  defp made_meet(event), do: event

  defp google_requests do
    receive do
      {:google, method, uri, body} -> [{method, uri, body} | google_requests()]
    after
      0 -> []
    end
  end

  defp use_runtime_calendar do
    calendar_module = Application.get_env(:tymeslot, :calendar_module)
    google_api = Application.get_env(:tymeslot, :google_calendar_api_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)
    Application.put_env(:tymeslot, :google_calendar_api_module, CalendarAPI)

    on_exit(fn ->
      Application.put_env(:tymeslot, :calendar_module, calendar_module)
      Application.put_env(:tymeslot, :google_calendar_api_module, google_api)
    end)
  end
end
