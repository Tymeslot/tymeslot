defmodule Tymeslot.Bookings.RescheduleTeamsCalendarEventTest do
  @moduledoc """
  A booking whose Microsoft Teams meeting sits on its own Outlook event (the
  calendar and the Teams integration are one Microsoft account), rescheduled
  to a location without Teams.

  Graph keeps the online meeting on an event once `isOnlineMeeting` is set, so
  updating the event would leave the Teams join block on the organiser's
  calendar. The event is replaced instead: a new one written without an online
  meeting, recorded on the booking, then the old one deleted. Walked from
  `Tymeslot.Bookings.Reschedule.execute/4` through the calendar jobs it sets
  off and the real Outlook calendar client, with only Graph (HTTP) mocked, and
  on to inbound sync reporting the old event gone.
  """

  # Not async: the calendar module is swapped application-wide for the real
  # runtime one, and the email mock is shared the same way.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.{CalendarEventWorker, VideoRoomWorker, VideoSyncWorker}

  setup :verify_on_exit!

  @account_id "entra-oid-organiser"
  @calendar_id "AAMk-calendar"
  @teams_event "AAMk-teams-event"
  @replacement_event "AAMk-replacement-event"
  @events_url "https://graph.microsoft.com/v1.0/me/calendars/#{@calendar_id}/events"

  setup do
    TestMocks.setup_email_mocks()
    TestMocks.stub_no_calendar_events()

    %{user: user} = create_always_bookable_profile()

    calendar =
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
        user_id: user.id,
        duration_minutes: 60,
        locations: [
          %LocationOption{
            id: "loc-teams",
            kind: "video",
            label: "Teams",
            video_integration_ids: [teams.id],
            position: 0
          },
          %LocationOption{
            id: "loc-office",
            kind: "in_person",
            label: "Our office",
            details: "12 High Street",
            position: 1
          }
        ]
      )

    meeting =
      insert_meeting_for_user(user, %{
        meeting_type_id: meeting_type.id,
        location: "https://teams.microsoft.com/l/meetup-join/19%3ameeting",
        location_kind: "video",
        location_option_id: "loc-teams",
        video_integration_id: teams.id,
        video_provider: "teams",
        video_room_id: @teams_event,
        meeting_url: "https://teams.microsoft.com/l/meetup-join/19%3ameeting",
        attendee_video_url: "https://teams.microsoft.com/l/meetup-join/19%3ameeting",
        organizer_video_url: "https://teams.microsoft.com/l/meetup-join/19%3ameeting",
        video_room_enabled: true,
        calendar_integration_id: calendar.id,
        calendar_path: @calendar_id,
        provider_event_id: @teams_event
      })

    %{calendar: calendar, meeting: meeting}
  end

  test "moving to the office replaces the Outlook event with one without the Teams meeting",
       %{meeting: meeting} do
    reschedule_to_office(meeting)

    # The video job never touches the event: calendar sync replaces it.
    refute_enqueued(worker: VideoSyncWorker)
    refute_enqueued(worker: VideoRoomWorker)

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "replace", "meeting_id" => meeting.id, "event_id" => @teams_event}
    )

    run_calendar_jobs(meeting)
    calls = graph_calls()

    # One new event, written without an online meeting and at the new place.
    assert [created] = for({:graph, :post, @events_url, body, _id} <- calls, do: body)
    refute Map.has_key?(created, "isOnlineMeeting")
    refute Map.has_key?(created, "onlineMeetingProvider")
    assert created["location"]["displayName"] =~ "Our office"

    # The old event is deleted, and only once the booking points at the new
    # one, so inbound sync can never mistake the deletion for the booking's.
    deletes = for {:graph, :delete, url, _body, id_at_delete} <- calls, do: {url, id_at_delete}
    assert deletes == [{"#{@events_url}/#{@teams_event}", @replacement_event}]

    updated = Repo.get!(MeetingSchema, meeting.id)
    assert updated.provider_event_id == @replacement_event
    assert updated.status == "confirmed"
    assert updated.calendar_sync_status == nil
    assert updated.video_room_id == nil
  end

  # The reschedule queues the calendar update before the replacement, so the
  # queue ordinarily runs the update first (the test above). A retried update
  # can land after the replacement instead; it must then move the new event,
  # never write to the old one or bring the Teams meeting back.
  test "an update running after the replacement writes to the new event only",
       %{meeting: meeting} do
    reschedule_to_office(meeting)

    jobs = all_enqueued(worker: CalendarEventWorker, queue: :calendar_events)
    assert [replace] = for(%{args: %{"action" => "replace"} = args} <- jobs, do: args)
    assert [update] = for(%{args: %{"action" => "update"} = args} <- jobs, do: args)

    stub_graph(meeting)
    assert :ok = perform_job(CalendarEventWorker, replace)
    assert :ok = perform_job(CalendarEventWorker, update)
    calls = graph_calls()

    assert [_created] = for({:graph, :post, @events_url, body, _id} <- calls, do: body)

    assert for({:graph, :delete, url, _body, _id} <- calls, do: url) ==
             ["#{@events_url}/#{@teams_event}"]

    # The update addresses the replacement, and nothing after the delete
    # touches the old event again.
    assert [patched] =
             for(
               {:graph, :patch, url, body, _id} <- calls,
               url == "#{@events_url}/#{@replacement_event}",
               do: body
             )

    refute Map.has_key?(patched, "isOnlineMeeting")
    refute Enum.any?(calls, &match?({:graph, :patch, "#{@events_url}/#{@teams_event}", _, _}, &1))

    updated = Repo.get!(MeetingSchema, meeting.id)
    assert updated.provider_event_id == @replacement_event
    assert updated.status == "confirmed"
  end

  test "the old event's removal arriving through inbound sync leaves the booking standing",
       %{calendar: calendar, meeting: meeting} do
    reschedule_to_office(meeting)
    run_calendar_jobs(meeting)

    # Outlook's delta reports the deleted event by its Graph id.
    assert :ok =
             Sync.reconcile_deletions(calendar, [%{provider_event_id: @teams_event, uid: nil}])

    updated = Repo.get!(MeetingSchema, meeting.id)
    assert updated.status == "confirmed"
    assert updated.calendar_sync_status == nil
  end

  defp reschedule_to_office(meeting) do
    params = %{
      date: Date.to_string(Date.add(Date.utc_today(), 2)),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "America/New_York",
      location_option_id: "loc-office"
    }

    assert {:ok, _updated} =
             Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)
  end

  # Runs every calendar job the reschedule set off, in queue order, against
  # the real calendar client and Outlook API, with Graph answering over a
  # mocked HTTP client that reports each request to the test. A delete also
  # reports which event the booking pointed at when it was sent.
  defp run_calendar_jobs(meeting) do
    stub_graph(meeting)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :calendar_events)
  end

  defp stub_graph(meeting) do
    use_runtime_calendar()
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      sent = if is_binary(body) and body != "", do: Jason.decode!(body), else: %{}
      pointed_at = Repo.get!(MeetingSchema, meeting.id).provider_event_id
      send(test_pid, {:graph, method, url, sent, pointed_at})
      graph_response(method, url, sent)
    end)
  end

  defp graph_response(:delete, _url, _sent), do: {:ok, %Req.Response{status: 204, body: ""}}

  defp graph_response(method, url, sent) do
    id = if method == :post, do: @replacement_event, else: url |> String.split("/") |> List.last()

    {:ok,
     %Req.Response{
       status: if(method == :post, do: 201, else: 200),
       body: Jason.encode!(Map.merge(sent, %{"id" => id, "iCalUId" => "ical-#{id}"}))
     }}
  end

  defp graph_calls do
    receive do
      {:graph, _method, _url, _body, _id} = call -> [call | graph_calls()]
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
