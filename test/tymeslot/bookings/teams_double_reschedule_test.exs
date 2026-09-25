defmodule Tymeslot.Bookings.TeamsDoubleRescheduleTest do
  @moduledoc """
  A booking whose Microsoft Teams meeting sits on its own Outlook event (the
  calendar and the Teams integration are one Microsoft account), rescheduled
  twice or more in quick succession.

  Each reschedule sets off its own jobs on two queues that do not wait for one
  another: the calendar queue, which updates the booking's event or replaces
  it when a location without Teams leaves the online meeting stranded on it
  (`Tymeslot.Meetings.CalendarEventSync.replace/3`), and the video queue,
  where `Tymeslot.Workers.VideoRoomWorker` switches the Teams meeting on for
  the booking's event. Here those jobs are run by hand in each order they can
  take, including one job running inside another's Graph request, which is
  how two jobs on different queues overlap in production.

  Microsoft Graph is a small stateful fake: it remembers which events exist
  and which carry an online meeting, answers a write to a deleted event with
  404, and can run a step of the test before or after answering a given
  request. Everything above HTTP is the real code.

  Whatever the order, the end state must be the one a single reschedule
  leaves: one live event in the organiser's calendar, the booking pointing at
  it, a Teams meeting on it only if the booking is at the Teams location, and
  the Teams link on the booking and in its emails being that event's.
  """

  # Not async: the calendar module is swapped application-wide for the real
  # runtime one, room creation runs through the application-wide Teams circuit
  # breaker, and the email mock is shared.
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
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  @account_id "entra-oid-organiser"
  @calendar_id "AAMk-calendar"
  @first_event "AAMk-first-event"
  @graph "https://graph.microsoft.com/v1.0"
  @events_url "#{@graph}/me/calendars/#{@calendar_id}/events"

  setup do
    TestMocks.setup_email_mocks()
    TestMocks.stub_no_calendar_events()
    stub(Tymeslot.TeamsOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    test_pid = self()

    stub(Tymeslot.EmailServiceMock, :send_reschedule_emails, fn details ->
      send(test_pid, {:reschedule_email, details})
      {{:ok, :organizer}, {:ok, :attendee}}
    end)

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

    %{user: user, calendar: calendar, teams: teams, meeting_type: meeting_type}
  end

  describe "Teams, then the office, then Teams again" do
    setup :teams_booking

    test "the replacement running before the room job: Teams moves onto the replacement",
         %{meeting: meeting} do
      reschedule(meeting, 2, "loc-office")
      reschedule(meeting, 3, "loc-teams")

      drain_calendar_queue()
      assert :ok = run_room_job(meeting)
      drain_calendar_queue()

      assert_teams_on_the_live_event(meeting)
      refute Map.has_key?(live_events(), @first_event)
      assert_last_email_link(meeting)
    end

    test "the room job running before the replacement: the first event is kept as it is",
         %{meeting: meeting} do
      reschedule(meeting, 2, "loc-office")
      reschedule(meeting, 3, "loc-teams")

      assert :ok = run_room_job(meeting)
      drain_calendar_queue()

      assert_teams_on_the_live_event(meeting)
      assert Map.keys(live_events()) == [@first_event]
      refute Enum.any?(graph_calls(), &match?({:post, @events_url}, &1))
      assert_last_email_link(meeting)
    end

    # The replacement reads the meeting without a room, the room job switches
    # Teams on for the first event and records it, then the replacement records
    # its new event and deletes the first one: the room it just deleted.
    test "the room attached while the replacement is creating its new event",
         %{meeting: meeting} do
      reschedule(meeting, 2, "loc-office")
      reschedule(meeting, 3, "loc-teams")

      on_request(:post, @events_url, :before, fn -> assert :ok = run_room_job(meeting) end)
      drain_calendar_queue()

      assert_teams_on_the_live_event(meeting)
      assert_last_email_link(meeting)
    end

    # The room job reads the meeting on the first event and switches Teams on
    # for it; before its answer is recorded, the replacement writes the new
    # event and deletes the first one. The room job then declines to record a
    # room on an event that is gone and hands over to a fresh copy of itself,
    # which switches Teams on for the replacement.
    test "the replacement completing while the room's attach request is in flight",
         %{meeting: meeting} do
      reschedule(meeting, 2, "loc-office")
      reschedule(meeting, 3, "loc-teams")

      on_request(:patch, "#{@graph}/me/events/#{@first_event}", :after, fn ->
        drain_calendar_queue()
      end)

      assert :ok = run_room_job(meeting)
      assert Repo.get!(MeetingSchema, meeting.id).video_room_id == nil

      assert :ok = run_room_job(meeting)
      drain_calendar_queue()

      assert_teams_on_the_live_event(meeting)
      assert_last_email_link(meeting)
    end

    # The same overlap, but the first event is already gone when the attach
    # request reaches Graph: the room job fails, and its retry reads the
    # meeting again and finds the replacement.
    test "the replacement deleting the event before the attach request reaches it",
         %{meeting: meeting} do
      reschedule(meeting, 2, "loc-office")
      reschedule(meeting, 3, "loc-teams")

      on_request(:patch, "#{@graph}/me/events/#{@first_event}", :before, fn ->
        drain_calendar_queue()
      end)

      assert {:error, _reason} = run_room_job(meeting)
      assert :ok = run_room_job(meeting, attempt: 2)
      drain_calendar_queue()

      assert_teams_on_the_live_event(meeting)
      refute Map.has_key?(live_events(), @first_event)
      assert_last_email_link(meeting)
    end
  end

  describe "Teams, then the office, Teams, and the office again" do
    setup :teams_booking

    test "all three before any job runs: one replacement, and no room",
         %{meeting: meeting} do
      reschedule(meeting, 2, "loc-office")
      reschedule(meeting, 3, "loc-teams")
      reschedule(meeting, 4, "loc-office")

      assert {:discard, _reason} = run_room_job(meeting)
      drain_calendar_queue()

      assert_no_teams_on_the_live_event(meeting)
      refute Map.has_key?(live_events(), @first_event)
    end

    # The second reschedule's room job has put Teams back on the first event,
    # so the first replacement, when it runs, reads a room on its event and
    # only updates it. The third reschedule moves the booking to the office
    # during that update and asks for the first event to be replaced again,
    # which Oban folds into the replacement job already running.
    test "the third reschedule landing while the first replacement updates the event",
         %{meeting: meeting} do
      reschedule(meeting, 2, "loc-office")
      reschedule(meeting, 3, "loc-teams")
      assert :ok = run_room_job(meeting)

      # The update the reschedules queued, then the replacement on its own.
      assert %{success: 1} = drain_calendar_queue(with_limit: 1)

      on_request(:patch, "#{@events_url}/#{@first_event}", :before, fn ->
        reschedule(meeting, 4, "loc-office")
      end)

      assert %{success: 1} = drain_calendar_queue(with_limit: 1)
      drain_calendar_queue()

      assert_no_teams_on_the_live_event(meeting)
      refute Map.has_key?(live_events(), @first_event)
    end
  end

  describe "the office, then Teams, then a second reschedule" do
    setup :office_booking

    test "back to the office while the room's attach request is in flight",
         %{meeting: meeting} do
      reschedule(meeting, 2, "loc-teams")

      on_request(:patch, "#{@graph}/me/events/#{@first_event}", :after, fn ->
        reschedule(meeting, 3, "loc-office")
      end)

      assert :ok = run_room_job(meeting)
      drain_calendar_queue()

      assert_no_teams_on_the_live_event(meeting)
      refute Map.has_key?(live_events(), @first_event)
    end

    # The second reschedule keeps the Teams location and moves the time only.
    # It is sent at once, before the room exists, so without a link; the room
    # job owes the first reschedule's announcement, which is now stale, and
    # rightly drops it. Nobody sends the link.
    test "a time-only reschedule before the room job runs still reaches the attendee with the link",
         %{meeting: meeting} do
      reschedule(meeting, 2, "loc-teams")
      reschedule(meeting, 3, "loc-teams")

      assert :ok = run_room_job(meeting)
      drain_calendar_queue()

      assert_teams_on_the_live_event(meeting)
      assert_last_email_link(meeting)
    end
  end

  describe "time-only reschedules around a replacement" do
    setup :teams_booking

    test "the office, then another time at the office, before the replacement runs",
         %{meeting: meeting} do
      reschedule(meeting, 2, "loc-office")
      rescheduled = reschedule(meeting, 3, "loc-office")

      drain_calendar_queue()

      assert_no_teams_on_the_live_event(meeting)
      assert [{_id, event}] = Map.to_list(live_events())
      assert DateTime.compare(event_start(event), rescheduled.start_time) == :eq
    end

    test "another time on Teams, then the office, before any job runs",
         %{meeting: meeting} do
      reschedule(meeting, 2, "loc-teams")
      rescheduled = reschedule(meeting, 3, "loc-office")

      drain_calendar_queue()

      assert_no_teams_on_the_live_event(meeting)
      assert [{_id, event}] = Map.to_list(live_events())
      assert DateTime.compare(event_start(event), rescheduled.start_time) == :eq
    end
  end

  # ---------------------------------------------------------------------------
  # Bookings
  # ---------------------------------------------------------------------------

  defp teams_booking(%{user: user, calendar: calendar, teams: teams, meeting_type: type}) do
    meeting =
      insert_meeting_for_user(user, %{
        meeting_type_id: type.id,
        location: join_url(@first_event),
        location_kind: "video",
        location_option_id: "loc-teams",
        video_integration_id: teams.id,
        video_provider: "teams",
        video_room_id: @first_event,
        meeting_url: join_url(@first_event),
        attendee_video_url: join_url(@first_event),
        organizer_video_url: join_url(@first_event),
        video_room_enabled: true,
        calendar_integration_id: calendar.id,
        calendar_path: @calendar_id,
        provider_event_id: @first_event
      })

    start_graph(%{@first_event => %{online: true, start: nil}})
    %{meeting: meeting}
  end

  defp office_booking(%{user: user, calendar: calendar, meeting_type: type}) do
    meeting =
      insert_meeting_for_user(user, %{
        meeting_type_id: type.id,
        location: "Our office: 12 High Street",
        location_kind: "in_person",
        location_option_id: "loc-office",
        calendar_integration_id: calendar.id,
        calendar_path: @calendar_id,
        provider_event_id: @first_event
      })

    start_graph(%{@first_event => %{online: false, start: nil}})
    %{meeting: meeting}
  end

  defp reschedule(meeting, days_ahead, option_id) do
    params = %{
      date: Date.to_string(Date.add(Date.utc_today(), days_ahead)),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "America/New_York",
      location_option_id: option_id
    }

    assert {:ok, updated} =
             Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

    updated
  end

  # ---------------------------------------------------------------------------
  # Jobs
  # ---------------------------------------------------------------------------

  # The newest room job the reschedules queued: the one owing the latest
  # announcement.
  defp run_room_job(meeting, opts \\ []) do
    jobs = all_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})
    assert [_job | _more] = jobs
    perform_job(VideoRoomWorker, Enum.max_by(jobs, & &1.id).args, opts)
  end

  defp drain_calendar_queue(opts \\ []) do
    result = Oban.drain_queue(Keyword.merge([queue: :calendar_events], opts))
    assert %{failure: 0, discard: 0} = result
    result
  end

  # ---------------------------------------------------------------------------
  # End state
  # ---------------------------------------------------------------------------

  # One event, the booking's, carrying the Teams meeting whose link the booking
  # hands out.
  defp assert_teams_on_the_live_event(meeting) do
    updated = Repo.get!(MeetingSchema, meeting.id)
    events = live_events()

    assert [live_id] = Map.keys(events)
    assert updated.provider_event_id == live_id
    assert updated.video_room_id == live_id
    assert events[live_id].online
    assert updated.meeting_url == join_url(live_id)
    assert String.starts_with?(updated.attendee_video_url, join_url(live_id))
  end

  defp assert_no_teams_on_the_live_event(meeting) do
    updated = Repo.get!(MeetingSchema, meeting.id)
    events = live_events()

    assert [live_id] = Map.keys(events)
    assert updated.provider_event_id == live_id
    refute events[live_id].online
    assert updated.video_room_id == nil
    assert updated.meeting_url == nil
  end

  # The last reschedule email announces the booking's time now, with the link
  # of the Teams meeting it is actually held in.
  defp assert_last_email_link(meeting) do
    updated = Repo.get!(MeetingSchema, meeting.id)
    emails = reschedule_emails()
    assert [_email | _more] = emails
    last = List.last(emails)

    assert DateTime.compare(last.start_time, updated.start_time) == :eq
    assert last.meeting_url == join_url(updated.provider_event_id)
  end

  defp reschedule_emails do
    receive do
      {:reschedule_email, details} -> [details | reschedule_emails()]
    after
      0 -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Microsoft Graph
  # ---------------------------------------------------------------------------

  defp join_url(event_id), do: "https://teams.microsoft.com/l/meetup-join/#{event_id}"

  defp event_start(%{start: %{"dateTime" => local, "timeZone" => zone}}),
    do: local |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!(zone)

  # Graph as a map of the events that exist, each with whether it carries an
  # online meeting, plus one-shot hooks run before or after a given request is
  # answered. A hook runs in whichever process made the request, outside the
  # agent, so it may make requests of its own.
  defp start_graph(events) do
    use_runtime_calendar()

    graph =
      start_supervised!(
        {Agent, fn -> %{events: events, next: 1, calls: [], hooks: []} end},
        id: :graph
      )

    Process.put(:graph, graph)

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      sent = if is_binary(body) and body != "", do: Jason.decode!(body), else: %{}
      run_hook(graph, method, url, :before)
      response = Agent.get_and_update(graph, &answer(&1, method, url, sent))
      run_hook(graph, method, url, :after)
      response
    end)
  end

  defp on_request(method, url, phase, fun) do
    Agent.update(Process.get(:graph), fn state ->
      %{state | hooks: state.hooks ++ [{method, url, phase, fun}]}
    end)
  end

  defp run_hook(graph, method, url, phase) do
    hook =
      Agent.get_and_update(graph, fn state ->
        case Enum.split_with(state.hooks, &match?({^method, ^url, ^phase, _fun}, &1)) do
          {[{_m, _u, _p, fun} | rest], others} -> {fun, %{state | hooks: rest ++ others}}
          {[], _others} -> {nil, state}
        end
      end)

    if hook, do: hook.()
  end

  defp live_events, do: Agent.get(Process.get(:graph), & &1.events)

  defp graph_calls do
    Process.get(:graph)
    |> Agent.get(& &1.calls)
    |> Enum.reverse()
  end

  defp answer(state, method, url, sent) do
    state = %{state | calls: [{method, url} | state.calls]}
    respond(state, method, url, sent)
  end

  # Reads (the booking's calendar check) find nothing in the way.
  defp respond(state, :get, _url, _sent), do: {reply(200, %{"value" => []}), state}

  defp respond(state, :post, @events_url, sent) do
    id = "AAMk-event-#{state.next}"
    event = %{online: sent["isOnlineMeeting"] == true, start: sent["start"]}
    state = %{state | next: state.next + 1, events: Map.put(state.events, id, event)}
    {reply(201, event_body(id, event, sent)), state}
  end

  defp respond(state, :delete, url, _sent) do
    id = event_id(url)

    if Map.has_key?(state.events, id),
      do: {reply(204, ""), %{state | events: Map.delete(state.events, id)}},
      else: {not_found(), state}
  end

  defp respond(state, :patch, url, sent) do
    id = event_id(url)

    case state.events do
      %{^id => event} ->
        event = %{
          online: event.online or sent["isOnlineMeeting"] == true,
          start: sent["start"] || event.start
        }

        {reply(200, event_body(id, event, sent)), put_in(state.events[id], event)}

      _missing ->
        {not_found(), state}
    end
  end

  defp event_id(url), do: url |> String.split("/") |> List.last()

  defp event_body(id, event, sent) do
    sent
    |> Map.merge(%{"id" => id, "iCalUId" => "ical-#{id}"})
    |> Map.merge(
      if event.online, do: %{"onlineMeeting" => %{"joinUrl" => join_url(id)}}, else: %{}
    )
  end

  defp not_found do
    reply(404, %{"error" => %{"code" => "ErrorItemNotFound", "message" => "Not found"}})
  end

  defp reply(status, ""), do: {:ok, %Req.Response{status: status, body: ""}}
  defp reply(status, body), do: {:ok, %Req.Response{status: status, body: Jason.encode!(body)}}

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
