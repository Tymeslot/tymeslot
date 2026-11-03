defmodule Tymeslot.Bookings.OutlookCreateTimeoutTest do
  @moduledoc """
  A booking's Outlook event create whose answer is lost: Microsoft Graph
  writes the event, but the response arrives after Tymeslot's receive timeout
  (or the worker's deadline), so the job never learns the event's id and
  retries. The retry must find the event the lost attempt wrote rather than
  write a second copy, which the host would see twice and an attendee would
  be invited to twice.

  Graph is simulated over the HTTP client. It keeps the events it is sent and
  answers a create carrying a `transactionId` it has seen with the event that
  id first wrote, deleted or not, which is what `transactionId` is for. The
  timeout is simulated where it happens: the fake stores the event and then
  answers with the `Req.TransportError` a receive timeout produces.
  """

  # Not async: the calendar module is swapped application-wide for the real
  # runtime one.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker

  setup :verify_on_exit!

  @calendar_id "AAMk-calendar"

  setup do
    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    %{user: user} = create_always_bookable_profile()

    insert(:calendar_integration,
      user: user,
      provider: "outlook",
      oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite offline_access",
      access_token_encrypted: Encryption.encrypt("graph-access-token"),
      refresh_token_encrypted: Encryption.encrypt("graph-refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      default_booking_calendar_id: @calendar_id
    )

    meeting_type =
      insert(:meeting_type, user: user, name: "Consultation", duration_minutes: 30)

    # Booked against the stubbed calendar, so only the calendar job reaches
    # the simulated Graph.
    meeting = book(user, meeting_type)
    use_runtime_calendar()

    %{meeting: meeting, graph: start_fake_graph()}
  end

  test "a create whose answer was lost is not written a second time on retry", %{
    meeting: meeting,
    graph: graph
  } do
    lose_next_create_answer(graph)

    refute run_create(meeting, 1) == :ok
    assert [lost] = live_events(graph)

    assert :ok = run_create(meeting, 2)

    assert [event] = live_events(graph)
    assert event["id"] == lost["id"]
    assert Repo.get!(MeetingSchema, meeting.id).provider_event_id == lost["id"]
  end

  test "an event deleted from Outlook is written anew, not answered with the deleted one", %{
    meeting: meeting,
    graph: graph
  } do
    assert :ok = run_create(meeting, 1)
    assert [first] = live_events(graph)

    delete_in_outlook(graph, first["id"])

    assert :ok =
             perform_job(CalendarEventWorker, %{"meeting_id" => meeting.id, "action" => "update"})

    assert [second] = live_events(graph)
    assert second["id"] != first["id"]
    assert Repo.get!(MeetingSchema, meeting.id).provider_event_id == second["id"]
  end

  test "a meeting moved while the answer was lost is written at its new time", %{
    meeting: meeting,
    graph: graph
  } do
    lose_next_create_answer(graph)
    refute run_create(meeting, 1) == :ok

    moved_start = DateTime.add(meeting.start_time, 3600, :second)

    meeting
    |> Changeset.change(
      start_time: moved_start,
      end_time: DateTime.add(meeting.end_time, 3600, :second)
    )
    |> Repo.update!()

    assert :ok = run_create(meeting, 2)

    recorded = Repo.get!(MeetingSchema, meeting.id).provider_event_id
    assert %{"start" => %{"dateTime" => start}} = event(graph, recorded)
    assert String.starts_with?(start, Calendar.strftime(moved_start, "%Y-%m-%dT%H:%M"))
  end

  test "a video link attached while the answer was lost lands on the one event", %{
    meeting: meeting,
    graph: graph
  } do
    lose_next_create_answer(graph)
    refute run_create(meeting, 1) == :ok

    # The room's own update runs before the create's retry: it finds no
    # recorded event and recovers by creating one, with the link in its body,
    # which Graph must answer with the event the lost create wrote.
    room_url = "https://meet.example.com/room-1"
    meeting |> Changeset.change(meeting_url: room_url) |> Repo.update!()

    assert :ok =
             perform_job(CalendarEventWorker, %{"meeting_id" => meeting.id, "action" => "update"})

    assert :ok = run_create(meeting, 2)

    assert [event] = live_events(graph)
    assert Repo.get!(MeetingSchema, meeting.id).provider_event_id == event["id"]
    assert %{"location" => %{"displayName" => ^room_url}} = event
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
        meeting_type_id: meeting_type.id
      }
    }

    assert {:ok, booked} = Orchestrator.submit_booking(params, organizer_user_id: user.id)
    booked
  end

  defp run_create(meeting, attempt) do
    perform_job(CalendarEventWorker, %{"meeting_id" => meeting.id, "action" => "create"},
      attempt: attempt
    )
  end

  # The fake's state: every event Graph holds (`deleted` ones included, since
  # Graph still answers a replayed `transactionId` with them), and whether the
  # next create's answer is to be lost.
  defp start_fake_graph do
    {:ok, graph} = Agent.start_link(fn -> %{events: %{}, lose_next: false} end)

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      sent = if is_binary(body) and body != "", do: Jason.decode!(body), else: %{}
      id = url |> URI.parse() |> Map.fetch!(:path) |> String.split("/") |> List.last()
      Agent.get_and_update(graph, &answer(&1, method, id, sent))
    end)

    graph
  end

  defp answer(state, :post, _path_id, sent) do
    event = replayed(state, sent["transactionId"]) || new_event(state, sent)

    reply =
      if state.lose_next,
        do: {:error, %Req.TransportError{reason: :timeout}},
        else: {:ok, %Req.Response{status: 201, body: Jason.encode!(event)}}

    {reply, %{put_in(state.events[event["id"]], event) | lose_next: false}}
  end

  defp answer(state, :get, id, _sent), do: {found(state, id), state}

  defp answer(state, :patch, id, sent) do
    case live(state, id) do
      nil -> {not_found(), state}
      event -> reply_stored(state, Map.merge(event, sent))
    end
  end

  defp answer(state, :delete, id, _sent) do
    case live(state, id) do
      nil -> {not_found(), state}
      event -> {{:ok, %Req.Response{status: 204, body: ""}}, put_deleted(state, event)}
    end
  end

  defp replayed(_state, nil), do: nil

  defp replayed(state, transaction_id) do
    state.events |> Map.values() |> Enum.find(&(&1["transactionId"] == transaction_id))
  end

  defp new_event(state, sent) do
    id = "AAMk-event-#{map_size(state.events) + 1}"

    Map.merge(sent, %{"id" => id, "iCalUId" => "ical-#{id}"})
  end

  defp reply_stored(state, event) do
    {{:ok, %Req.Response{status: 200, body: Jason.encode!(event)}},
     put_in(state.events[event["id"]], event)}
  end

  defp put_deleted(state, event),
    do: put_in(state.events[event["id"]], Map.put(event, "deleted", true))

  defp found(state, id) do
    case live(state, id) do
      nil -> not_found()
      event -> {:ok, %Req.Response{status: 200, body: Jason.encode!(event)}}
    end
  end

  defp live(state, id) do
    case state.events[id] do
      %{"deleted" => true} -> nil
      event -> event
    end
  end

  defp not_found do
    {:ok,
     %Req.Response{
       status: 404,
       body: Jason.encode!(%{"error" => %{"code" => "ErrorItemNotFound"}})
     }}
  end

  defp lose_next_create_answer(graph), do: Agent.update(graph, &%{&1 | lose_next: true})

  defp delete_in_outlook(graph, id),
    do: Agent.update(graph, &put_deleted(&1, &1.events[id]))

  defp live_events(graph) do
    graph
    |> Agent.get(& &1.events)
    |> Map.values()
    |> Enum.reject(& &1["deleted"])
  end

  defp event(graph, id), do: Agent.get(graph, & &1.events[id])

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
