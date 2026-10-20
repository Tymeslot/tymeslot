defmodule Tymeslot.CalendarGrid.ChangesCreateTest do
  @moduledoc """
  Creating an event through `Changes.create_event/2`, the one create the
  calendar calls: what reaches the calendar (the place and free/busy
  included), the cache row the calendar reads back before any sync, the
  guests' invitations, and the organiser's availability.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "google", is_active: true)
    %{user: user, integration: integration}
  end

  defp payload(integration, creating \\ %{}) do
    %{
      creating:
        Map.merge(
          %{title: "Lunch", integration_id: integration.id, calendar_id: "work", attendees: []},
          creating
        ),
      start_at: ~U[2026-10-15 12:00:00Z],
      end_at: ~U[2026-10-15 13:00:00Z],
      timezone: "Europe/London"
    }
  end

  defp written(opts \\ []) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
      send(test_pid, {:event_data, event_data})
      {:ok, CreatedEvent.new(event_data.uid, opts)}
    end)
  end

  defp cached(integration, uid) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
    row
  end

  test "writes the place and free/busy to the calendar", %{user: user, integration: integration} do
    written()

    assert {:ok, _created} =
             Changes.create_event(
               user.id,
               payload(integration, %{location: "Room 4", transparency: "transparent"})
             )

    assert_receive {:event_data, event_data}
    assert event_data.location == "Room 4"
    assert event_data.transparency == "transparent"
  end

  test "leaves the place and free/busy out when none was given",
       %{user: user, integration: integration} do
    written()

    assert {:ok, _created} = Changes.create_event(user.id, payload(integration))

    assert_receive {:event_data, event_data}
    refute Map.has_key?(event_data, :location)
    refute Map.has_key?(event_data, :transparency)
  end

  test "caches the row the calendar reads back, with what the provider reported",
       %{user: user, integration: integration} do
    written(provider_event_id: "g-123", etag: "etag-1")

    assert {:ok, %{event: event, invited: ["anna@example.com"]}} =
             Changes.create_event(
               user.id,
               payload(integration, %{
                 location: "Room 4",
                 transparency: "transparent",
                 attendees: ["anna@example.com"],
                 reminders: [%{method: :popup, minutes_before: 10}],
                 recurrence_rule: "FREQ=WEEKLY;BYDAY=TH"
               })
             )

    row = cached(integration, event.uid)
    assert row.id == event.id
    assert row.summary == "Lunch"
    assert row.location == "Room 4"
    assert row.transparency == "transparent"
    assert row.provider_calendar_id == "work"
    assert row.provider_event_id == "g-123"
    assert row.etag == "etag-1"
    assert row.recurrence_rule == "FREQ=WEEKLY;BYDAY=TH"
    assert [%{"method" => "popup", "minutes_before" => 10}] = row.reminders
    assert [%{"email" => "anna@example.com"}] = row.attendees
    assert DateTime.compare(row.start_at, ~U[2026-10-15 12:00:00Z]) == :eq
  end

  test "caches the notes with the call's join line, and the call's room and link",
       %{user: user, integration: integration} do
    video_integration = insert(:video_integration, user: user, provider: "mirotalk")

    body =
      Jason.encode!(%{
        "room_id" => "room-123",
        "meeting_url" => "https://video.example.com/join/room-123"
      })

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: body}}
    end)

    written()

    {:ok, %{event: event}} =
      Changes.create_event(
        user.id,
        payload(integration, %{
          description: "Weekly sync",
          video_integration_id: video_integration.id
        })
      )

    row = cached(integration, event.uid)
    assert row.description =~ "Weekly sync"
    assert row.description =~ "https://video.example.com/join/room-123"
    assert row.video_link == "https://video.example.com/join/room-123"
    assert row.video_integration_id == video_integration.id
  end

  # A CalDAV server is only obliged to answer a PUT with an ETag when it
  # stored the document unmodified, so the columns stay null rather than the
  # create being treated as failed.
  test "leaves the identity columns null when the provider reported neither",
       %{user: user, integration: integration} do
    written()

    {:ok, %{event: event}} = Changes.create_event(user.id, payload(integration))

    row = cached(integration, event.uid)
    assert is_nil(row.provider_event_id)
    assert is_nil(row.etag)
  end

  test "a busy event is cached as busy", %{user: user, integration: integration} do
    written()

    {:ok, %{event: event}} = Changes.create_event(user.id, payload(integration))

    assert cached(integration, event.uid).transparency == "opaque"
  end

  test "files the row under the calendar the provider wrote to",
       %{user: user, integration: integration} do
    written(calendar_id: "family")

    {:ok, %{event: event}} = Changes.create_event(user.id, payload(integration))

    assert cached(integration, event.uid).provider_calendar_id == "family"
  end

  test "caches an all-day event by its dates", %{user: user, integration: integration} do
    written()

    all_day =
      integration
      |> payload(%{all_day: true})
      |> Map.merge(%{start_at: ~D[2026-10-16], end_at: ~D[2026-10-18]})

    {:ok, %{event: event}} = Changes.create_event(user.id, all_day)

    row = cached(integration, event.uid)
    assert row.all_day
    assert {row.start_date, row.end_date} == {~D[2026-10-16], ~D[2026-10-18]}
    assert is_nil(row.start_at)
  end

  test "invites the guests", %{user: user, integration: integration} do
    written()

    {:ok, %{event: event}} =
      Changes.create_event(user.id, payload(integration, %{attendees: ["anna@example.com"]}))

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_calendar_invitation",
        "attendee_email" => "anna@example.com",
        "event_uid" => event.uid
      }
    )
  end

  test "drops the organiser's cached availability", %{user: user, integration: integration} do
    written()

    key =
      AvailabilityCache.availability_range_key(
        user.id,
        ~D[2026-10-01],
        ~D[2026-10-31],
        "UTC",
        30,
        nil,
        nil
      )

    assert "stale" == AvailabilityCache.get_or_compute(key, fn -> "stale" end)

    {:ok, _created} = Changes.create_event(user.id, payload(integration))

    assert "fresh" == AvailabilityCache.get_or_compute(key, fn -> "fresh" end)
  end

  test "a create the calendar refused caches nothing", %{user: user, integration: integration} do
    expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
      {:error, :forbidden}
    end)

    assert {:error, %{reason: :forbidden, retry: :not_queued}} =
             Changes.create_event(user.id, payload(integration))

    assert Repo.all(ProviderCalendarEventSchema) == []
  end

  test "creates from a checked quick-create intent", %{user: user, integration: integration} do
    written()

    integration = %{
      integration
      | calendar_list: [
          %Tymeslot.Integrations.Calendar.CalendarEntry{id: "work", name: "Work", selected: true}
        ]
    }

    {:ok, params} =
      CreateParams.cast(
        user.id,
        [integration],
        %{
          "title" => "Lunch",
          "start" => "2026-10-15T13:00",
          "end" => "2026-10-15T14:00",
          "calendar" => "#{integration.id}:work",
          "location" => "Café Rose",
          "free" => true
        },
        "Europe/London"
      )

    assert {:ok, %{event: event}} = Changes.create_event(user.id, params)

    assert_receive {:event_data, event_data}
    assert event_data.summary == "Lunch"
    assert event_data.location == "Café Rose"
    assert event_data.transparency == "transparent"
    assert cached(integration, event.uid).transparency == "transparent"
  end
end
