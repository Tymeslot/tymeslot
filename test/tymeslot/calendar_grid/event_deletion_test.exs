defmodule Tymeslot.CalendarGrid.EventDeletionTest do
  @moduledoc """
  `CalendarGrid.delete_event/3` deletes an event on its calendar, cancels the
  Tymeslot meeting it was booked as, and removes the cached row, or queues the
  delete for the next sync when the calendar could not be reached. A member of
  a series goes in the scope asked for: its one occurrence, or the series.

  The provider delete is stubbed at the suite-wide `:calendar_module` seam
  (`Tymeslot.CalendarMock`), where `Calendar.Events.delete_event/3`
  dispatches.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Ecto.Query, only: [select: 3, where: 3]
  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  setup do
    user = insert(:user)

    caldav =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    %{user: user, caldav: caldav}
  end

  defp insert_event(integration, attrs \\ %{}) do
    defaults = %{
      calendar_integration: integration,
      uid: "event-#{System.unique_integer([:positive])}",
      summary: "Design review",
      provider: integration.provider,
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/design-review.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp expect_delete(result) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :delete_event, fn uid, context, opts ->
      send(test_pid, {:deleted, uid, context, opts})
      result
    end)
  end

  describe "delete_event/3 when the calendar deletes the event" do
    test "addresses the event by its provider id and removes the cached row", %{
      user: user,
      caldav: caldav
    } do
      event = insert_event(caldav)
      expect_delete(:ok)

      assert {:ok, result} = CalendarGrid.delete_event(user.id, event)

      assert result == %{
               uid: event.uid,
               integration_id: caldav.id,
               linked_meeting: :none,
               attendees_notified: :none
             }

      assert_received {:deleted, uid, context, opts}

      assert {uid, context, opts} ==
               {event.uid, {caldav.id, user.id},
                [provider_event_id: "/cal/design-review.ics", calendar_id: "/cal/"]}

      assert {:error, :not_found} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
    end

    test "invalidates the organiser's cached availability", %{user: user, caldav: caldav} do
      event = insert_event(caldav)
      expect_delete(:ok)

      key = AvailabilityCache.booking_window_events_key(user.id)
      :ok = AvailabilityCache.put(key, :stale)

      assert {:ok, _result} = CalendarGrid.delete_event(user.id, event)
      assert AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :recomputed
    end

    test "addresses an event without a provider id by its uid", %{user: user, caldav: caldav} do
      event = insert_event(caldav, %{provider_event_id: nil})
      expect_delete(:ok)

      assert {:ok, _result} = CalendarGrid.delete_event(user.id, event)
      # No href to address the event by, but the calendar it is on is still
      # known and still narrows the delete.
      assert_received {:deleted, _uid, _context, [calendar_id: "/cal/"]}
    end

    test "cancels the meeting the event was booked as", %{user: user, caldav: caldav} do
      TestMocks.setup_email_mocks()
      event = insert_event(caldav)

      meeting =
        insert(:meeting,
          calendar_integration_id: caldav.id,
          provider_event_id: event.provider_event_id,
          attendee_email: "guest@example.com"
        )

      expect_delete(:ok)

      assert {:ok, %{linked_meeting: :cancelled}} = CalendarGrid.delete_event(user.id, event)

      {:ok, cancelled} = MeetingQueries.get_meeting(meeting.id)

      assert {cancelled.status, cancelled.calendar_sync_status} ==
               {"cancelled", "externally_deleted"}
    end
  end

  describe "delete_event/3 when the calendar refuses the delete" do
    test "queues a CalDAV delete for the next sync", %{user: user, caldav: caldav} do
      event = insert_event(caldav)
      expect_delete({:error, :network_error})
      key = AvailabilityCache.booking_window_events_key(user.id)
      :ok = AvailabilityCache.put(key, :stale)

      assert {:error, %{reason: :network_error, retry: :queued}} =
               CalendarGrid.delete_event(user.id, event)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
      assert row.sync_state == "locally_deleted"

      # The event is still on the calendar until the queued delete lands, and
      # the grid puts it back, so the slot it holds must not be offered to
      # bookers in the meantime.
      assert AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :stale
    end

    test "does not queue a delete a retry cannot recover", %{user: user, caldav: caldav} do
      event = insert_event(caldav)
      expect_delete({:error, :unauthorized})

      assert {:error, %{reason: :unauthorized, retry: :not_queued}} =
               CalendarGrid.delete_event(user.id, event)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
      assert {row.sync_state, row.summary} == {"synced", "Design review"}
    end

    test "leaves the linked meeting alone", %{user: user, caldav: caldav} do
      event = insert_event(caldav)

      meeting =
        insert(:meeting,
          calendar_integration_id: caldav.id,
          provider_event_id: event.provider_event_id
        )

      expect_delete({:error, :network_error})

      assert {:error, _failure} = CalendarGrid.delete_event(user.id, event)

      {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
      assert {unchanged.status, unchanged.calendar_sync_status} == {meeting.status, nil}
    end

    test "keeps the event on a calendar without an offline queue", %{user: user} do
      google = insert(:calendar_integration, user: user, provider: "google")
      event = insert_event(google, %{provider_calendar_id: "primary"})
      expect_delete({:error, :network_error})

      assert {:error, %{reason: :network_error, retry: :not_queued}} =
               CalendarGrid.delete_event(user.id, event)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(google.id, event.uid)
      assert row.sync_state == "synced"
    end
  end

  describe "deletion_scopes/1" do
    test "a one-off event is deleted on its own", %{caldav: caldav} do
      assert CalendarGrid.deletion_scopes(insert_event(caldav)) == {:ok, :single}
    end

    test "an occurrence of a Google series takes a scope", %{user: user} do
      google = insert(:calendar_integration, user: user, provider: "google")
      event = insert_event(google, google_occurrence("series-1", "20260601T090000Z"))

      assert CalendarGrid.deletion_scopes(event) == {:ok, :series}
    end

    test "an occurrence of a CalDAV series takes a scope", %{caldav: caldav} do
      event = insert_event(caldav, caldav_occurrence("20260601T090000"))

      assert CalendarGrid.deletion_scopes(event) == {:ok, :series}
    end

    test "an occurrence edited on its own takes a scope", %{caldav: caldav} do
      event = insert_event(caldav, caldav_override("20260602T090000"))

      assert CalendarGrid.deletion_scopes(event) == {:ok, :series}
    end

    test "an occurrence of an Exchange series cannot be deleted", %{user: user} do
      exchange = insert(:calendar_integration, user: user, provider: "exchange")
      event = insert_event(exchange, exchange_occurrence())

      assert CalendarGrid.deletion_scopes(event) == {:error, :recurring_event}
    end

    test "reads the series from the cached row when handed only the address", %{caldav: caldav} do
      event = insert_event(caldav, caldav_occurrence("20260601T090000"))
      address = %{uid: event.uid, calendar_integration_id: caldav.id}

      assert CalendarGrid.deletion_scopes(address) == {:ok, :series}
    end
  end

  for provider <- ["google", "outlook"] do
    describe "delete_event/3 on an occurrence of a #{provider} series" do
      setup %{user: user} do
        integration = insert(:calendar_integration, user: user, provider: unquote(provider))

        %{
          integration: integration,
          first: insert_event(integration, google_occurrence("series-1", "20260601T090000Z")),
          second: insert_event(integration, google_occurrence("series-1", "20260608T090000Z")),
          unrelated: insert_event(integration, %{provider_event_id: "one-off"})
        }
      end

      test ":occurrence deletes the occurrence by its own id and keeps the rest", %{
        user: user,
        integration: integration,
        first: first,
        second: second,
        unrelated: unrelated
      } do
        expect_delete(:ok)

        assert {:ok, %{linked_meeting: :none}} =
                 CalendarGrid.delete_event(user.id, first, :occurrence)

        assert_received {:deleted, _uid, _context, opts}
        assert opts == [provider_event_id: "series-1_20260601T090000Z", calendar_id: "primary"]

        assert cached_uids(integration) == Enum.sort([second.uid, unrelated.uid])
      end

      test ":series deletes the master and every cached row of the series", %{
        user: user,
        integration: integration,
        first: first,
        unrelated: unrelated
      } do
        insert_event(integration, %{
          provider_event_id: "series-1",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"
        })

        expect_delete(:ok)

        assert {:ok, %{uid: uid, linked_meeting: :none}} =
                 CalendarGrid.delete_event(user.id, first, :series)

        assert uid == first.uid
        assert_received {:deleted, _uid, _context, opts}
        assert opts == [provider_event_id: "series-1", calendar_id: "primary"]
        assert cached_uids(integration) == [unrelated.uid]
      end

      test ":series from the master's own row addresses the master by its id", %{
        user: user,
        integration: integration,
        unrelated: unrelated
      } do
        master =
          insert_event(integration, %{
            provider_event_id: "series-1",
            recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"
          })

        expect_delete(:ok)

        assert {:ok, _deleted} = CalendarGrid.delete_event(user.id, master, :series)
        assert_received {:deleted, _uid, _context, [provider_event_id: "series-1"] ++ _rest}
        assert cached_uids(integration) == [unrelated.uid]
      end

      # The master's own id would take the whole series.
      test ":occurrence is refused on the master's own row", %{
        user: user,
        integration: integration
      } do
        master =
          insert_event(integration, %{
            provider_event_id: "series-1",
            recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"
          })

        assert {:error, %{reason: :unaddressable_occurrence, retry: :not_queued}} =
                 CalendarGrid.delete_event(user.id, master, :occurrence)
      end
    end
  end

  describe "delete_event/3 on an occurrence of a CalDAV series" do
    test "refuses an occurrence whose uid does not carry its series' UID", %{
      user: user,
      caldav: caldav
    } do
      event = insert_event(caldav, %{recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"})

      assert {:error, %{reason: :unaddressable_occurrence, retry: :not_queued}} =
               CalendarGrid.delete_event(user.id, event, :occurrence)

      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
    end

    # The queue replays a delete as a DELETE of the whole resource, which would
    # take every occurrence with the one the organiser meant.
    test "a failed delete is not queued", %{user: user, caldav: caldav} do
      event = insert_event(caldav, caldav_occurrence("20260601T090000"))
      expect_delete({:error, :network_error})

      assert {:error, %{reason: :network_error, retry: :not_queued}} =
               CalendarGrid.delete_event(user.id, event, :occurrence)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
      assert row.sync_state == "synced"
    end

    test "a failed delete of the whole series is not queued either", %{
      user: user,
      caldav: caldav
    } do
      event = insert_event(caldav, caldav_occurrence("20260601T090000"))
      expect_delete({:error, :network_error})

      assert {:error, %{reason: :network_error, retry: :not_queued}} =
               CalendarGrid.delete_event(user.id, event, :series)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
      assert row.sync_state == "synced"
    end

    # The occurrence shares its href with the whole series, so a meeting
    # matched by it would be cancelled although the series stands.
    test "leaves a meeting matched by the series' href alone", %{user: user, caldav: caldav} do
      event = insert_event(caldav, caldav_occurrence("20260601T090000"))

      meeting =
        insert(:meeting,
          calendar_integration_id: caldav.id,
          provider_event_id: event.provider_event_id
        )

      expect_delete({:ok, %{document: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"}})

      assert {:ok, %{linked_meeting: :none}} =
               CalendarGrid.delete_event(user.id, event, :occurrence)

      {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
      assert {unchanged.status, unchanged.calendar_sync_status} == {meeting.status, nil}
    end
  end

  describe "delete_event/3 on the video rooms of a series" do
    test ":series deletes the room recorded for the series", %{user: user, caldav: caldav} do
      event = insert_event(caldav, caldav_occurrence("20260602T090000"))
      room = insert_room(user, caldav, "weekly-standup", event.provider_event_id)
      expect_delete(:ok)

      assert {:ok, _deleted} = CalendarGrid.delete_event(user.id, event, :series)

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"event_room_id" => room.id, "action" => "delete"}
      )
    end

    # The override carries no repeat rule, yet the room recorded under the
    # series' href is the one every other occurrence still meets in.
    test ":occurrence keeps the room the rest of the series uses", %{
      user: user,
      caldav: caldav
    } do
      event = insert_event(caldav, caldav_override("20260602T090000"))
      insert_room(user, caldav, "weekly-standup", event.provider_event_id)
      expect_delete({:ok, %{document: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"}})

      assert {:ok, _deleted} =
               CalendarGrid.delete_event(
                 user.id,
                 %{
                   uid: event.uid,
                   calendar_integration_id: caldav.id,
                   provider_event_id: event.provider_event_id
                 },
                 :occurrence
               )

      refute_enqueued(worker: VideoSyncWorker)
    end
  end

  # No provider expectation is set in these tests: under `verify_on_exit!` a
  # delete that reached the calendar would fail them as an unexpected call.
  describe "delete_event/3 on an occurrence of an Exchange series" do
    setup %{user: user} do
      exchange = insert(:calendar_integration, user: user, provider: "exchange")
      %{exchange: exchange, event: insert_event(exchange, exchange_occurrence())}
    end

    for scope <- [:occurrence, :series] do
      test "refuses #{scope} and leaves calendar and cache alone", %{
        user: user,
        exchange: exchange,
        event: event
      } do
        assert {:error, %{reason: :recurring_event, retry: :not_queued}} =
                 CalendarGrid.delete_event(user.id, event, unquote(scope))

        assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(exchange.id, event.uid)
        assert row.sync_state == "synced"
      end
    end
  end

  describe "delete_event/3 when a series delete fails" do
    test "a Google series delete is not queued and keeps every row", %{user: user} do
      google = insert(:calendar_integration, user: user, provider: "google")
      first = insert_event(google, google_occurrence("series-1", "20260601T090000Z"))
      second = insert_event(google, google_occurrence("series-1", "20260608T090000Z"))
      expect_delete({:error, :network_error})

      assert {:error, %{reason: :network_error, retry: :not_queued}} =
               CalendarGrid.delete_event(user.id, first, :series)

      assert cached_uids(google) == Enum.sort([first.uid, second.uid])
    end
  end

  defp cached_uids(integration) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^integration.id)
    |> select([e], e.uid)
    |> Repo.all()
    |> Enum.sort()
  end

  # An expanded Google or Outlook occurrence: an id of its own, naming its
  # master's.
  defp google_occurrence(series_id, stamp) do
    %{
      uid: "#{series_id}@google.com_#{stamp}",
      provider_calendar_id: "primary",
      provider_event_id: "#{series_id}_#{stamp}",
      recurring_event_id: series_id
    }
  end

  # An expanded CalDAV occurrence: the series' href and repeat rule, and its
  # series' UID followed by the occurrence's key.
  defp caldav_occurrence(key) do
    %{
      uid: "weekly-standup_#{key}",
      provider_event_id: "/cal/weekly-standup.ics",
      recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
      provider_metadata: %{"uid" => "weekly-standup"}
    }
  end

  # A CalDAV occurrence edited on its own: no repeat rule, only the
  # recurrence id the sync keeps in the metadata.
  defp caldav_override(key) do
    %{
      uid: "weekly-standup_#{key}",
      provider_event_id: "/cal/weekly-standup.ics",
      provider_metadata: %{"uid" => "weekly-standup", "recurrence_id" => key}
    }
  end

  defp exchange_occurrence do
    %{
      provider_calendar_id: "calendar",
      provider_event_id: "AAMkAD-occurrence",
      provider_metadata: %{"calendar_item_type" => "Occurrence"}
    }
  end

  defp insert_room(user, calendar, event_uid, provider_event_id) do
    base_url = "https://talk.example.com"

    talk =
      insert(:video_integration,
        user: user,
        provider: "nextcloud_talk",
        base_url: base_url,
        client_id_encrypted: Encryption.encrypt("organiser"),
        client_secret_encrypted: Encryption.encrypt("Abcde-Fghij-Klmno-Pqrst-Uvwxy"),
        provider_account_id: base_url <> "||organiser"
      )

    {:ok, room} =
      EventVideoRoomQueries.insert(%{
        user_id: user.id,
        video_integration_id: talk.id,
        provider: "nextcloud_talk",
        calendar_integration_id: calendar.id,
        event_uid: event_uid,
        provider_event_id: provider_event_id,
        room_id: "room0001",
        lobby_opens_at: ~U[2026-06-02 09:00:00Z],
        ends_at: ~U[2026-06-02 10:00:00Z]
      })

    room
  end
end
