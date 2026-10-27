defmodule Tymeslot.CalendarGrid.EventMoveOwnershipTest do
  @moduledoc """
  A move to another CalDAV calendar creates the event afresh under a new
  uid, and the CalDAV sync reads ownership off that uid alone. Somebody
  else's event must come out of the move, and out of the destination's next
  sync, still somebody else's; Tymeslot's own must stay Tymeslot's on both.

  The create is stubbed at the `:calendar_module` seam, and the sync is the
  real CalDAV parse, normalise and cache of the resource the create wrote.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Sync

  setup :verify_on_exit!

  setup do
    user = insert(:user)

    source =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/src/"])

    destination =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/dest/"])

    test_pid = self()

    expect(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:created, payload})
      {:ok, CreatedEvent.new(payload.uid)}
    end)

    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

    %{user: user, source: source, destination: destination}
  end

  defp insert_event(integration, attrs) do
    defaults = %{
      calendar_integration: integration,
      summary: "Design review",
      provider: integration.provider,
      provider_calendar_id: "/src/",
      provider_event_id: "/src/design-review.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp move(user, event, destination),
    do: CalendarGrid.move_event(user.id, event, %{integration: destination, calendar_id: nil})

  # The destination's next sync reading back the resource the move wrote.
  defp sync_destination(destination, uid) do
    resource = """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    BEGIN:VEVENT\r
    UID:#{uid}\r
    DTSTAMP:20260520T090000Z\r
    DTSTART:20260601T090000Z\r
    DTEND:20260601T100000Z\r
    SUMMARY:Design review\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    {:ok, parsed} = EventProcessor.parse_ical_events(resource)
    raws = Enum.map(parsed, &Map.merge(&1, %{href: "/dest/#{uid}.ics", etag: "etag-2"}))

    context = %{
      calendar_integration_id: destination.id,
      provider_calendar_id: "/dest/",
      calendar_paths: ["/dest/"],
      synced_at: DateTime.utc_now()
    }

    {:ok, normalised} = EventProcessor.normalise_events(raws, context)
    {:ok, 1} = Sync.upsert_cache(destination, normalised)

    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(destination.id, uid)
    row
  end

  test "somebody else's event stays theirs after the move and the next sync", %{
    user: user,
    source: source,
    destination: destination
  } do
    event = insert_event(source, %{uid: "invite@example.com", created_by_tymeslot: false})

    assert {:ok, %{uid: uid}} = move(user, event, destination)

    assert_received {:created, %{uid: ^uid, created_by_tymeslot: false}}
    refute String.ends_with?(uid, "@tymeslot.com")

    assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(destination.id, uid)
    refute row.created_by_tymeslot
    refute sync_destination(destination, uid).created_by_tymeslot
  end

  test "Tymeslot's own event stays Tymeslot's after the move and the next sync", %{
    user: user,
    source: source,
    destination: destination
  } do
    event = insert_event(source, %{uid: "own@tymeslot.com", created_by_tymeslot: true})

    assert {:ok, %{uid: uid}} = move(user, event, destination)

    assert String.ends_with?(uid, "@tymeslot.com")
    assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(destination.id, uid)
    assert row.created_by_tymeslot
    assert sync_destination(destination, uid).created_by_tymeslot
  end

  test "an event created on the grid stays Tymeslot's when moved before its first sync", %{
    user: user,
    source: source,
    destination: destination
  } do
    :ok =
      CalendarGrid.cache_created_event(%{
        uid: "fresh@tymeslot.com",
        calendar_integration_id: source.id,
        provider: source.provider,
        provider_calendar_id: "/src/",
        summary: "Design review",
        start_at: ~U[2026-06-01 09:00:00Z],
        end_at: ~U[2026-06-01 10:00:00Z]
      })

    {:ok, event} = ProviderCalendarEventQueries.get_by_uid(source.id, "fresh@tymeslot.com")

    assert {:ok, %{uid: uid}} = move(user, event, destination)

    assert String.ends_with?(uid, "@tymeslot.com")
    assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(destination.id, uid)
    assert row.created_by_tymeslot
    assert sync_destination(destination, uid).created_by_tymeslot
  end
end
