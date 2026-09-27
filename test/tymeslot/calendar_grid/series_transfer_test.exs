defmodule Tymeslot.CalendarGrid.SeriesTransferTest do
  @moduledoc """
  Moving a member of a recurring series to another calendar moves the whole
  series (`Tymeslot.CalendarGrid.SeriesTransfer`): which members take a
  series move, which moves are refused before anything is written, and what
  every family's writer shares once the destination holds the series.

  The steps after the write are driven through a writer handed to
  `SeriesTransfer.move/4`, which answers as a real one would; the CalDAV
  family's own writer is exercised down to the HTTP client in
  `Tymeslot.CalendarGrid.SeriesTransferCalDAVTest`. The one-off move's provider writes sit behind
  `Tymeslot.CalendarMock`, which every refusal here asserts is never
  reached.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.SeriesTransfer
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    google = insert(:calendar_integration, user: user, provider: "google")
    %{user: user, google: google}
  end

  # A Google occurrence as the sync caches it: its uid and id end in its
  # original start, and it names its master.
  defp google_occurrence(integration, attrs \\ %{}) do
    insert_row(
      integration,
      Map.merge(
        %{
          uid: "standup@google.com_20261005T090000Z",
          provider_event_id: "master1_20261005T090000Z",
          recurring_event_id: "master1",
          provider_calendar_id: "primary"
        },
        attrs
      )
    )
  end

  defp caldav_series(integration, attrs \\ %{}) do
    insert_row(
      integration,
      Map.merge(
        %{
          uid: "standup@example.com",
          provider_event_id: "/src/standup.ics",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
          provider_calendar_id: "/src/"
        },
        attrs
      )
    )
  end

  defp insert_row(integration, attrs) do
    defaults = %{
      calendar_integration: integration,
      provider: integration.provider,
      summary: "Weekly standup",
      start_at: ~U[2026-10-05 09:00:00.000000Z],
      end_at: ~U[2026-10-05 09:30:00.000000Z],
      all_day: false,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp caldav_integration(user, provider \\ "caldav", paths \\ ["/dest/"]),
    do: insert(:calendar_integration, user: user, provider: provider, calendar_paths: paths)

  defp move(user, event, integration, calendar_id \\ nil) do
    CalendarGrid.move_event(user.id, event, %{integration: integration, calendar_id: calendar_id})
  end

  # The one-off move's create and delete: a series move must never reach them.
  defp refute_one_off_writes do
    expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context ->
      {:ok, CreatedEvent.new("never")}
    end)

    expect(Tymeslot.CalendarMock, :delete_event, 0, fn _uid, _context, _opts -> :ok end)
  end

  defp assert_untouched(row) do
    assert {:ok, _row} =
             ProviderCalendarEventQueries.get_by_uid(row.calendar_integration_id, row.uid)

    assert all_enqueued() == []
  end

  # What a writer answers, reporting the transfer it was handed.
  defp writer(answer) do
    test_pid = self()

    fn family, transfer ->
      send(test_pid, {:writer, family, transfer})
      answer
    end
  end

  defp written(attrs \\ %{}) do
    {:ok,
     Map.merge(
       %{uid: "moved@google.com", id: "newmaster", calendar_id: "team", source: :removed},
       attrs
     )}
  end

  defp series_move(user, stored, integration, answer, calendar_id \\ nil) do
    SeriesTransfer.move(
      user.id,
      stored,
      %{integration: integration, calendar_id: calendar_id},
      writer: writer(answer)
    )
  end

  defp insert_room(user, integration, attrs) do
    talk = insert(:video_integration, user: user, provider: "nextcloud_talk")
    ends = DateTime.add(DateTime.utc_now(:second), 30 * 86_400, :second)

    {:ok, room} =
      EventVideoRoomQueries.insert(
        Map.merge(
          %{
            user_id: user.id,
            video_integration_id: talk.id,
            provider: "nextcloud_talk",
            calendar_integration_id: integration.id,
            room_id: "room-#{System.unique_integer([:positive])}",
            lobby_opens_at: DateTime.add(ends, -900, :second),
            ends_at: ends
          },
          attrs
        )
      )

    room
  end

  describe "ensure_movable/1" do
    test "moves an event outside any series on its own", %{user: user} do
      event = insert_row(caldav_integration(user), %{uid: "offsite", provider_event_id: "/o.ics"})

      assert CalendarGrid.ensure_movable(event) == :ok
    end

    test "moves a Google occurrence with its series", %{google: google} do
      assert CalendarGrid.ensure_movable(google_occurrence(google)) == {:ok, :series}
    end

    test "moves an Outlook occurrence with its series", %{user: user} do
      outlook = insert(:calendar_integration, user: user, provider: "outlook")
      event = insert_row(outlook, %{uid: "AAMk-occ", recurring_event_id: "AAMk-master"})

      assert CalendarGrid.ensure_movable(event) == {:ok, :series}
    end

    test "moves a CalDAV series with itself", %{user: user} do
      assert CalendarGrid.ensure_movable(caldav_series(caldav_integration(user))) ==
               {:ok, :series}
    end

    test "refuses an Exchange series, which has no series-wide write", %{user: user} do
      exchange = insert(:calendar_integration, user: user, provider: "exchange")

      event =
        insert_row(exchange, %{
          uid: "weekly",
          provider_event_id: "series-item",
          provider_metadata: %{"calendar_item_type" => "RecurringMaster"}
        })

      assert CalendarGrid.ensure_movable(event) == {:error, :recurring_event}
    end

    # The grid hands in whatever it last assigned, which may be a copy that
    # lost its series markers; the cached row still has them.
    test "reads the cached row, not the copy it is handed", %{google: google} do
      event = google_occurrence(google)

      assert CalendarGrid.ensure_movable(%{event | recurring_event_id: nil}) == {:ok, :series}
    end
  end

  describe "move_event/3 of a series member, refused before anything is written" do
    test "a Google series to a CalDAV calendar is a move across families", %{
      user: user,
      google: google
    } do
      event = google_occurrence(google)
      refute_one_off_writes()

      assert move(user, event, caldav_integration(user)) == {:error, :cross_provider_series}
      assert_untouched(event)
    end

    test "a CalDAV series to Google is a move across families", %{user: user, google: google} do
      event = caldav_series(caldav_integration(user))
      refute_one_off_writes()

      assert move(user, event, google) == {:error, :cross_provider_series}
      assert_untouched(event)
    end

    test "a Google series to Outlook is a move across families", %{user: user, google: google} do
      event = google_occurrence(google)
      outlook = insert(:calendar_integration, user: user, provider: "outlook")
      refute_one_off_writes()

      assert move(user, event, outlook) == {:error, :cross_provider_series}
      assert_untouched(event)
    end

    test "an Exchange series is refused as recurring", %{user: user} do
      exchange = insert(:calendar_integration, user: user, provider: "exchange")

      event =
        insert_row(exchange, %{
          uid: "weekly",
          provider_event_id: "series-item",
          provider_metadata: %{"calendar_item_type" => "Occurrence"}
        })

      refute_one_off_writes()

      assert move(user, event, exchange) == {:error, :recurring_event}
      assert_untouched(event)
    end

    test "a Google master row with no id of its own names no series", %{
      user: user,
      google: google
    } do
      event =
        insert_row(google, %{
          uid: "standup@google.com",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
          provider_event_id: nil
        })

      other = insert(:calendar_integration, user: user, provider: "google")
      refute_one_off_writes()

      assert move(user, event, other) == {:error, :unaddressable_series}
      assert_untouched(event)
    end

    test "a CalDAV series with no href names no resource", %{user: user} do
      event = caldav_series(caldav_integration(user), %{provider_event_id: nil})
      refute_one_off_writes()

      assert move(user, event, caldav_integration(user)) == {:error, :unaddressable_series}
      assert_untouched(event)
    end

    test "a CalDAV destination with no collection has nowhere to write to", %{user: user} do
      event = caldav_series(caldav_integration(user))
      refute_one_off_writes()

      assert move(user, event, caldav_integration(user, "caldav", [])) ==
               {:error, :no_destination_calendar}

      assert_untouched(event)
    end
  end

  # Each family's writer lands on its own; until then the move is refused
  # without writing anything.
  describe "move_event/3 of a series member within its family, before its writer lands" do
    test "Google to another Google integration", %{user: user, google: google} do
      event = google_occurrence(google)
      refute_one_off_writes()

      destination = insert(:calendar_integration, user: user, provider: "google")
      assert move(user, event, destination) == {:error, :unsupported_scope}
      assert_untouched(event)
    end

    test "Outlook to Outlook", %{user: user} do
      outlook = insert(:calendar_integration, user: user, provider: "outlook")
      event = insert_row(outlook, %{uid: "AAMk-occ", recurring_event_id: "AAMk-master"})
      refute_one_off_writes()

      assert move(user, event, outlook, "AAMk-other-calendar") == {:error, :unsupported_scope}
      assert_untouched(event)
    end
  end

  describe "move/4 once the writer has written the series to the destination" do
    test "hands the writer the family, the series' address and the destination calendar", %{
      user: user,
      google: google
    } do
      event = google_occurrence(google)
      destination = insert(:calendar_integration, user: user, provider: "google")

      assert {:ok, _moved} = series_move(user, event, destination, written(), "team")

      assert_received {:writer, :google, transfer}

      assert %{user_id: user_id, address: {:master, "master1"}, calendar_id: "team"} = transfer
      assert user_id == user.id
      assert transfer.integration.id == destination.id
      assert transfer.stored.id == event.id
    end

    test "answers as a one-off move: the new series' uid on the destination", %{
      user: user,
      google: google
    } do
      event = google_occurrence(google)
      destination = insert(:calendar_integration, user: user, provider: "google")

      assert series_move(user, event, destination, written()) ==
               {:ok, %{uid: "moved@google.com", integration_id: destination.id}}
    end

    test "reports an original the writer could not delete as left behind", %{
      user: user,
      google: google
    } do
      event = google_occurrence(google)
      destination = insert(:calendar_integration, user: user, provider: "google")

      assert series_move(user, event, destination, written(%{source: :left_behind})) ==
               {:ok,
                %{uid: "moved@google.com", integration_id: destination.id, source: :left_behind}}
    end

    test "moves the series' video rooms to the destination integration", %{
      user: user,
      google: google
    } do
      event = google_occurrence(google)
      destination = insert(:calendar_integration, user: user, provider: "google")

      series_room =
        insert_room(user, google, %{
          event_uid: "standup@google.com",
          provider_event_id: "master1",
          provider_calendar_id: "primary"
        })

      other_room =
        insert_room(user, google, %{event_uid: "offsite@google.com", provider_event_id: "offsite"})

      assert {:ok, _moved} = series_move(user, event, destination, written())

      assert %{
               calendar_integration_id: calendar_integration_id,
               event_uid: "moved@google.com",
               provider_event_id: "newmaster",
               provider_calendar_id: "team"
             } = Repo.reload!(series_room)

      assert calendar_integration_id == destination.id
      assert Repo.reload!(other_room).calendar_integration_id == google.id
    end

    test "deletes every cached row of a Google series on the source, and nothing else", %{
      user: user,
      google: google
    } do
      event = google_occurrence(google)

      sibling =
        google_occurrence(google, %{
          uid: "standup@google.com_20261012T090000Z",
          provider_event_id: "master1_20261012T090000Z"
        })

      master =
        insert_row(google, %{
          uid: "standup@google.com",
          provider_event_id: "master1",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"
        })

      unrelated = insert_row(google, %{uid: "offsite@google.com", provider_event_id: "offsite"})
      destination = insert(:calendar_integration, user: user, provider: "google")

      assert {:ok, _moved} = series_move(user, event, destination, written())

      for row <- [event, sibling, master] do
        assert ProviderCalendarEventQueries.get_by_uid(google.id, row.uid) == {:error, :not_found}
      end

      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(google.id, unrelated.uid)
    end

    test "deletes every cached row of a CalDAV resource on the source, and nothing else", %{
      user: user
    } do
      source = caldav_integration(user)
      event = caldav_series(source)

      occurrence =
        caldav_series(source, %{
          uid: "standup@example.com_20261012T090000Z",
          recurrence_rule: nil,
          provider_metadata: %{"recurrence_id" => "20261012T090000Z"}
        })

      unrelated = insert_row(source, %{uid: "offsite", provider_event_id: "/src/offsite.ics"})
      destination = caldav_integration(user, "nextcloud")
      answer = written(%{uid: "moved@example.com", id: "/dest/moved@example.com.ics"})

      assert {:ok, _moved} = series_move(user, event, destination, answer)

      for row <- [event, occurrence] do
        assert ProviderCalendarEventQueries.get_by_uid(source.id, row.uid) == {:error, :not_found}
      end

      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(source.id, unrelated.uid)
    end

    test "invalidates the organiser's cached availability", %{user: user, google: google} do
      event = google_occurrence(google)
      destination = insert(:calendar_integration, user: user, provider: "google")
      key = AvailabilityCache.booking_window_events_key(user.id)
      :ok = AvailabilityCache.put(key, :stale)

      assert {:ok, _moved} = series_move(user, event, destination, written())
      assert AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :recomputed
    end

    test "requests a sync of the destination and of the source it left", %{user: user} do
      source = caldav_integration(user)
      destination = caldav_integration(user, "nextcloud")
      answer = written(%{uid: "moved@example.com", id: "/dest/moved@example.com.ics"})

      assert {:ok, _moved} = series_move(user, caldav_series(source), destination, answer)

      for integration <- [destination, source] do
        assert_enqueued(
          worker: SyncCalDavCalendarWorker,
          args: %{"calendar_integration_id" => integration.id, "force_full_fetch" => true}
        )
      end
    end

    test "requests one sync when the series stays on its integration", %{user: user} do
      outlook = insert(:calendar_integration, user: user, provider: "outlook")
      event = insert_row(outlook, %{uid: "AAMk-occ", recurring_event_id: "AAMk-master"})

      assert {:ok, _moved} = series_move(user, event, outlook, written(), "AAMk-other-calendar")

      assert [%{args: %{"calendar_integration_id" => integration_id}}] =
               all_enqueued(worker: RefreshOutlookCalendarWorker)

      assert integration_id == outlook.id
    end

    test "a writer that wrote nothing leaves the rows, the rooms and the syncs alone", %{
      user: user,
      google: google
    } do
      event = google_occurrence(google)
      destination = insert(:calendar_integration, user: user, provider: "google")

      room =
        insert_room(user, google, %{event_uid: "standup@google.com", provider_event_id: "master1"})

      assert series_move(user, event, destination, {:error, :forbidden}) == {:error, :forbidden}

      assert_untouched(event)
      assert Repo.reload!(room).calendar_integration_id == google.id
      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end
  end
end
