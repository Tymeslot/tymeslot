defmodule Tymeslot.CalendarGrid.EventMoveTest do
  @moduledoc """
  `CalendarGrid.move_event/3` creates the whole event on the destination
  before deleting the original, so no failure along the way can lose it.

  Both provider writes are stubbed at the suite-wide `:calendar_module` seam
  (`Tymeslot.CalendarMock`), which is where `Calendar.Events.create_event/2`
  and `delete_event/3` dispatch. Each stub reports its call to the test
  process, so the order of the two writes is observable.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid
  alias Tymeslot.ExchangeFixtures
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.Exchange.EventNormaliser
  alias Tymeslot.Integrations.Calendar.Exchange.Soap
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Sync

  setup :verify_on_exit!

  @attendees [%{"email" => "guest@example.com", "name" => "Guest", "status" => "accepted"}]
  @reminders [%{"method" => "popup", "minutes_before" => 15}]

  setup do
    user = insert(:user)

    source =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/src/"])

    destination =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        calendar_paths: ["/dest/home/", "/dest/work/"]
      )

    %{user: user, source: source, destination: destination}
  end

  defp insert_event(integration, attrs \\ %{}) do
    defaults = %{
      calendar_integration: integration,
      uid: "event-#{System.unique_integer([:positive])}",
      summary: "Design review",
      description: "Agenda\n\nJoin video call: https://video.example.com/room",
      location: "Room 4",
      provider: integration.provider,
      provider_calendar_id: "/src/",
      provider_event_id: "/src/design-review.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      attendees: @attendees,
      reminders: @reminders,
      colour: "tomato",
      transparency: "transparent",
      visibility: "private",
      etag: "\"etag-1\"",
      raw_ical: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n",
      video_link: "https://video.example.com/room",
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp insert_all_day_event(integration) do
    insert_event(integration, %{
      all_day: true,
      start_at: nil,
      end_at: nil,
      start_date: ~D[2026-06-01],
      end_date: ~D[2026-06-02]
    })
  end

  # Caches one Exchange item of `item_type` the way the grid's read path does:
  # a `GetItem` response through the Exchange normaliser into the cache.
  defp cache_exchange_item(user, item_type) do
    exchange = insert(:calendar_integration, user: user, provider: "exchange")

    {:ok, doc} =
      [id: "series-item", uid: "weekly-standup", calendar_item_type: item_type]
      |> ExchangeFixtures.get_item_response()
      |> Soap.parse()

    context = %{
      calendar_integration_id: exchange.id,
      provider_calendar_id: "calendar-folder",
      synced_at: DateTime.utc_now()
    }

    {:ok, normalised} =
      doc |> EventNormaliser.parse_items() |> EventNormaliser.normalise_events(context)

    {:ok, 1} = Sync.upsert_cache(exchange, normalised)
    {:ok, event} = ProviderCalendarEventQueries.get_by_uid(exchange.id, "weekly-standup")

    {exchange, event}
  end

  defp expect_create(result_fun) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :create_event, fn payload, context ->
      send(test_pid, {:provider_call, {:create, payload, context}})
      result_fun.(payload)
    end)
  end

  defp created(payload), do: {:ok, payload.uid}

  defp expect_delete(result) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :delete_event, fn uid, context, opts ->
      send(test_pid, {:provider_call, {:delete, uid, context, opts}})
      result
    end)
  end

  defp refute_delete,
    do: expect(Tymeslot.CalendarMock, :delete_event, 0, fn _uid, _context, _opts -> :ok end)

  defp provider_calls(calls \\ []) do
    receive do
      {:provider_call, call} -> provider_calls([call | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp move(user, event, integration, calendar_id \\ nil) do
    CalendarGrid.move_event(user.id, event, %{integration: integration, calendar_id: calendar_id})
  end

  describe "move_event/3 when the destination accepts the event" do
    test "creates on the destination before deleting the original", %{
      user: user,
      source: source,
      destination: destination
    } do
      event = insert_event(source)
      expect_create(&created/1)
      expect_delete(:ok)

      assert {:ok, %{uid: uid, integration_id: integration_id} = result} =
               move(user, event, destination)

      assert integration_id == destination.id
      refute Map.has_key?(result, :source)

      assert [{:create, payload, create_context}, {:delete, deleted_uid, delete_context, opts}] =
               provider_calls()

      assert payload.uid == uid
      assert uid != event.uid
      assert create_context == {destination.id, user.id}
      assert {deleted_uid, delete_context} == {event.uid, {source.id, user.id}}
      assert opts == [provider_event_id: "/src/design-review.ics"]
    end

    test "sends the whole event to the destination", %{
      user: user,
      source: source,
      destination: destination
    } do
      event = insert_event(source)
      expect_create(&created/1)
      expect_delete(:ok)

      assert {:ok, _moved} = move(user, event, destination)
      assert [{:create, payload, _context}, _delete] = provider_calls()

      assert payload.summary == "Design review"
      assert payload.description == event.description
      assert payload.location == "Room 4"
      assert {payload.start_time, payload.end_time} == {event.start_at, event.end_at}
      assert payload.all_day == false
      assert payload.attendees == @attendees
      assert payload.reminders == @reminders
      assert payload.colour == "tomato"
      assert payload.transparency == "transparent"
      assert payload.visibility == "private"
      refute Map.has_key?(payload, :provider_event_id)
    end

    test "sends an all-day event with its dates", %{
      user: user,
      source: source,
      destination: destination
    } do
      event = insert_all_day_event(source)
      expect_create(&created/1)
      expect_delete(:ok)

      assert {:ok, _moved} = move(user, event, destination)
      assert [{:create, payload, _context}, _delete] = provider_calls()

      assert {payload.start_time, payload.end_time} == {~D[2026-06-01], ~D[2026-06-02]}
      assert payload.all_day == true
    end

    test "caches the whole event on the destination and drops the original's row", %{
      user: user,
      source: source,
      destination: destination
    } do
      video = insert(:video_integration, user: user)
      event = insert_event(source, %{video_integration_id: video.id})
      expect_create(&created/1)
      expect_delete(:ok)

      assert {:ok, %{uid: uid}} = move(user, event, destination)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(destination.id, uid)
      assert row.summary == "Design review"
      assert row.description == event.description
      assert row.location == "Room 4"
      assert {row.start_at, row.end_at} == {event.start_at, event.end_at}
      assert row.attendees == @attendees
      assert row.reminders == @reminders
      assert row.colour == "tomato"
      assert row.video_link == "https://video.example.com/room"
      assert row.video_integration_id == video.id
      assert {row.etag, row.raw_ical, row.provider_event_id} == {nil, nil, nil}

      assert {:error, :not_found} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
    end

    test "files a CalDAV destination under the collection it wrote to, never \"primary\"", %{
      user: user,
      source: source,
      destination: destination
    } do
      event = insert_event(source)
      expect_create(&created/1)
      expect_delete(:ok)

      assert {:ok, %{uid: uid}} = move(user, event, destination)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(destination.id, uid)
      assert row.provider_calendar_id == "/dest/home/"
    end

    # Rediscovery can leave a booking calendar id that matches no collection,
    # which resolves no path. The CalDAV create writes to the first discovered
    # collection regardless, so the row has to follow it: filing the row under
    # a null is rejected by the column, and the event would sit on the
    # destination while the organiser is told nothing moved.
    test "files a CalDAV destination whose booking calendar id matches nothing under the first collection",
         %{user: user, source: source, destination: destination} do
      destination =
        destination
        |> Changeset.change(%{
          default_booking_calendar_id: "/dest/deleted/",
          calendar_list: [%{id: "/dest/home/", path: "/dest/home/", name: "Home"}]
        })
        |> Repo.update!()

      event = insert_event(source)
      expect_create(&created/1)
      expect_delete(:ok)

      assert {:ok, %{uid: uid}} = move(user, event, destination)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(destination.id, uid)
      assert row.provider_calendar_id == "/dest/home/"
    end

    test "refuses a destination with no collection at all, writing nothing", %{
      user: user,
      source: source,
      destination: destination
    } do
      destination =
        destination
        |> Changeset.change(%{calendar_paths: [], calendar_list: []})
        |> Repo.update!()

      event = insert_event(source)

      assert {:error, :no_destination_calendar} = move(user, event, destination)

      assert provider_calls() == []
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
    end

    test "files a Google destination under the chosen calendar, keyed by Google's id", %{
      user: user,
      source: source
    } do
      google = insert(:calendar_integration, user: user, provider: "google")
      event = insert_event(source)
      expect_create(fn _payload -> {:ok, %{uid: "google-event-id"}} end)
      expect_delete(:ok)

      assert {:ok, %{uid: "google-event-id"}} = move(user, event, google, "team@group.calendar")
      assert [{:create, payload, _context}, _delete] = provider_calls()
      assert payload.calendar_id == "team@group.calendar"

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(google.id, "google-event-id")
      assert row.provider_calendar_id == "team@group.calendar"
    end

    test "invalidates the organiser's cached availability", %{
      user: user,
      source: source,
      destination: destination
    } do
      event = insert_event(source)
      expect_create(&created/1)
      expect_delete(:ok)

      key = AvailabilityCache.booking_window_events_key(user.id)
      :ok = AvailabilityCache.put(key, :stale)

      assert {:ok, _moved} = move(user, event, destination)
      assert AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :recomputed
    end
  end

  describe "move_event/3 when the destination refuses the event" do
    test "deletes nothing and leaves the original's row as it was", %{
      user: user,
      source: source,
      destination: destination
    } do
      event = insert_event(source)
      expect_create(fn _payload -> {:error, :server_error} end)
      refute_delete()

      assert {:error, :server_error} = move(user, event, destination)
      assert [{:create, payload, _context}] = provider_calls()

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
      assert {row.sync_state, row.summary, row.etag} == {"synced", "Design review", "\"etag-1\""}

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(destination.id, payload.uid)
    end
  end

  describe "move_event/3 when the original cannot be deleted" do
    test "a CalDAV original is queued for deletion on the next sync", %{
      user: user,
      source: source,
      destination: destination
    } do
      event = insert_event(source)
      expect_create(&created/1)
      expect_delete({:error, :network_error})

      assert {:ok, %{uid: uid, source: :queued_delete}} = move(user, event, destination)

      assert {:ok, _destination_row} =
               ProviderCalendarEventQueries.get_by_uid(destination.id, uid)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
      assert row.sync_state == "locally_deleted"
    end

    test "a failure a retry cannot fix leaves the CalDAV original in place", %{
      user: user,
      source: source,
      destination: destination
    } do
      event = insert_event(source)
      expect_create(&created/1)
      expect_delete({:error, :unauthorized})

      assert {:ok, %{source: :left_behind}} = move(user, event, destination)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
      assert row.sync_state == "synced"
    end

    test "an original on a provider without an offline queue is left in place", %{
      user: user,
      destination: destination
    } do
      google = insert(:calendar_integration, user: user, provider: "google")
      event = insert_event(google, %{provider_calendar_id: "primary", provider_event_id: "g-1"})
      expect_create(&created/1)
      expect_delete({:error, :server_error})

      assert {:ok, %{uid: uid, source: :left_behind}} = move(user, event, destination)

      assert {:ok, _destination_row} =
               ProviderCalendarEventQueries.get_by_uid(destination.id, uid)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(google.id, event.uid)
      assert row.sync_state == "synced"
    end
  end

  describe "move_event/3 input guards" do
    for {kind, attrs} <- [
          series: quote(do: %{recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"}),
          occurrence: quote(do: %{recurring_event_id: "series-1"})
        ] do
      test "a recurring #{kind} is refused before anything is written", %{
        user: user,
        source: source,
        destination: destination
      } do
        event = insert_event(source, unquote(attrs))

        expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context ->
          {:ok, "never"}
        end)

        refute_delete()

        assert {:error, :recurring_event} = move(user, event, destination)
        assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
      end
    end

    # One CalDAV resource holds a series' master and every occurrence edited on
    # its own, and the sync caches the first VEVENT it finds there. When that is
    # the edited occurrence, its row carries no repeat rule and names no series,
    # yet its href is the whole series' resource: deleting the "original" after
    # the copy would delete every occurrence. The row is built by the sync's own
    # parse, normalise and cache steps, so a change to any of them that loses
    # the occurrence's marker turns this red.
    test "an occurrence edited on its own is refused before anything is written", %{
      user: user,
      source: source,
      destination: destination
    } do
      resource = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:standup@example.com
      RECURRENCE-ID:20261012T090000Z
      DTSTART:20261012T140000Z
      DTEND:20261012T150000Z
      SUMMARY:Weekly standup (moved to the afternoon)
      END:VEVENT
      BEGIN:VEVENT
      UID:standup@example.com
      DTSTART:20261005T090000Z
      DTEND:20261005T100000Z
      RRULE:FREQ=WEEKLY;COUNT=3
      SUMMARY:Weekly standup
      END:VEVENT
      END:VCALENDAR
      """

      {:ok, parsed} = EventProcessor.parse_ical_from_string(resource)
      raw = Map.merge(parsed, %{href: "/src/standup.ics", etag: "etag-1", raw_ical: resource})

      context = %{
        calendar_integration_id: source.id,
        provider_calendar_id: "/src/",
        calendar_paths: ["/src/"],
        synced_at: DateTime.utc_now()
      }

      {:ok, normalised} = EventProcessor.normalise_events([raw], context)
      {:ok, 1} = Sync.upsert_cache(source, normalised)
      {:ok, event} = ProviderCalendarEventQueries.get_by_uid(source.id, "standup@example.com")

      assert {event.recurrence_rule, event.recurring_event_id, event.provider_event_id} ==
               {nil, nil, "/src/standup.ics"}

      expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context -> {:ok, "never"} end)
      refute_delete()

      assert {:error, :recurring_event} = move(user, event, destination)
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
    end

    # EWS marks a series only by its item type: the normaliser writes no repeat
    # rule and names no series. A server that does not expand series (grommunio)
    # puts the RecurringMaster itself on the grid, and deleting it by its item
    # id after the copy would remove every occurrence. The row is built by the
    # sync's own parse, normalise and cache steps, so losing the marker in any
    # of them turns these red.
    for item_type <- ~w(RecurringMaster Occurrence Exception) do
      test "an Exchange #{item_type} is refused before anything is written", %{
        user: user,
        destination: destination
      } do
        {exchange, event} = cache_exchange_item(user, unquote(item_type))

        assert {event.recurrence_rule, event.recurring_event_id, event.provider_event_id} ==
                 {nil, nil, "series-item"}

        expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context ->
          {:ok, "never"}
        end)

        refute_delete()

        assert {:error, :recurring_event} = move(user, event, destination)
        assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(exchange.id, event.uid)
      end
    end

    test "a single Exchange item still moves, deleted by its item id", %{
      user: user,
      destination: destination
    } do
      {exchange, event} = cache_exchange_item(user, "Single")
      expect_create(&created/1)
      expect_delete(:ok)

      assert {:ok, %{uid: uid}} = move(user, event, destination)

      assert [{:create, _payload, _context}, {:delete, _uid, delete_context, opts}] =
               provider_calls()

      assert delete_context == {exchange.id, user.id}
      assert opts == [provider_event_id: "series-item"]
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(destination.id, uid)
    end

    test "an all-day event without dates never reaches the destination", %{
      user: user,
      source: source,
      destination: destination
    } do
      event = insert_event(source, %{all_day: true, start_at: nil, end_at: nil})
      expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context -> {:ok, "never"} end)
      refute_delete()

      assert {:error, :invalid_timing} = move(user, event, destination)
    end
  end
end
