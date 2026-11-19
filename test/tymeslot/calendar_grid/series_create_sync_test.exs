defmodule Tymeslot.CalendarGrid.SeriesCreateSyncTest do
  @moduledoc """
  A repeating event made in the calendar, whether created repeating or given
  a repeat rule by an edit, is cached at once as one row standing in for the
  whole series. The sync then caches the series' occurrences, each under the
  series' UID and the slot's key, and the stand-in must go as they arrive:
  left beside them, the series' first date shows the event twice on the
  grid, on the overview and in the agenda.

  Walked on the debug calendar, through the sync worker, and on a CalDAV
  calendar through a delta (sync-collection) sync, which reports what changed
  and so never prunes a row by its absence.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Test.ClockHelpers, only: [freeze_clock: 1]

  @moduletag :calendar
  @moduletag :integration

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.CalDAV.SyncReconciler
  alias Tymeslot.Integrations.Calendar.DebugStore
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SyncDebugCalendarWorker

  @href "/cal/weekly@tymeslot.com.ics"

  describe "on the debug calendar" do
    setup do
      previous_module = Application.get_env(:tymeslot, :calendar_module)
      Application.put_env(:tymeslot, :calendar_module, Operations)

      on_exit(fn ->
        if previous_module,
          do: Application.put_env(:tymeslot, :calendar_module, previous_module),
          else: Application.delete_env(:tymeslot, :calendar_module)
      end)

      start_supervised!(DebugStore)
      DebugStore.set_pattern(:empty)

      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "debug", is_active: true)

      # Tomorrow at 18:00 UTC: inside the window the debug sync reads, which
      # it measures from the real clock.
      first_start =
        DateTime.utc_now()
        |> DateTime.to_date()
        |> Date.add(1)
        |> DateTime.new!(~T[18:00:00], "Etc/UTC")

      %{user: user, integration: integration, first_start: first_start}
    end

    test "a series created repeating shows once on its first date after the sync", %{
      user: user,
      integration: integration,
      first_start: first_start
    } do
      {:ok, %{event: created}} =
        Changes.create_event(user.id, payload(integration, first_start, "FREQ=WEEKLY;COUNT=3"))

      sync_debug(integration)

      assert blocks_on(integration, first_start) == [created.uid <> "_" <> stamp(first_start)]
      assert length(blocks_over_weeks(integration, first_start, 3)) == 3
    end

    test "an event given a repeat rule by an edit shows once on its first date after the sync",
         %{user: user, integration: integration, first_start: first_start} do
      {:ok, %{event: created}} =
        Changes.create_event(user.id, payload(integration, first_start, nil))

      sync_debug(integration)
      assert blocks_on(integration, first_start) == [created.uid]

      {:ok, _updated} =
        Changes.update_event(user.id, created, %{recurrence_rule: "FREQ=WEEKLY;COUNT=3"},
          timezone: "Etc/UTC"
        )

      sync_debug(integration)

      assert blocks_on(integration, first_start) == [created.uid <> "_" <> stamp(first_start)]
      assert length(blocks_over_weeks(integration, first_start, 3)) == 3
    end
  end

  describe "on a CalDAV calendar synced by delta" do
    setup do
      # The window the CalDAV expansion reads is measured from this clock.
      # The series lies far ahead of the real clock too: an external deletion
      # of a meeting whose slot has elapsed by it is ignored
      # (`ExternalCalendarChanges`), so a past slot would let a booking test
      # pass whether or not the booking is cancelled.
      freeze_clock(~U[2099-11-10 12:00:00Z])

      integration =
        insert(:calendar_integration, provider: "caldav", calendar_paths: ["/cal/"])

      %{integration: integration, first_start: ~U[2099-11-18 18:00:00Z]}
    end

    test "the row cached at create time goes once the series' occurrences arrive", %{
      integration: integration,
      first_start: first_start
    } do
      cache_created_caldav_series(integration, first_start, %{})

      assert :ok = SyncReconciler.process_tier1(integration, caldav_series(@href), [])

      assert blocks_on(integration, first_start) == ["weekly@tymeslot.com_20991118T180000"]
      assert length(blocks_over_weeks(integration, first_start, 3)) == 3
    end

    # No sync writes a row's video, so the series' video, recorded on the row
    # cached at create time alone, would go with it.
    test "the occurrences are given the video of the row cached at create time", %{
      integration: integration,
      first_start: first_start
    } do
      video = insert(:video_integration, user: integration.user, provider: "mirotalk")
      link = "https://video.example.com/join/weekly"

      cache_created_caldav_series(integration, first_start, %{
        video_link: link,
        video_integration_id: video.id
      })

      assert :ok = SyncReconciler.process_tier1(integration, caldav_series(@href), [])

      occurrences = blocks_over_weeks(integration, first_start, 3)
      assert length(occurrences) == 3
      assert Enum.reject(occurrences, &(&1.video_link == link)) == []
      assert Enum.reject(occurrences, &(&1.video_integration_id == video.id)) == []
    end

    # An edit hands no video to a sync of its own (`SeriesCarry.series_created/1`
    # covers only a create), so the row the edit left is the one place it is.
    test "a one-off with a video given a repeat rule by an edit gives its occurrences the video",
         %{integration: integration, first_start: first_start} do
      video = insert(:video_integration, user: integration.user, provider: "mirotalk")
      link = "https://video.example.com/join/weekly"
      one_off = insert_synced_caldav_one_off(integration, first_start, video, link)

      {:ok, _row} =
        ProviderCalendarEventQueries.apply_local_edit(integration.id, one_off.uid, %{
          recurrence_rule: "FREQ=WEEKLY;COUNT=3"
        })

      assert :ok = SyncReconciler.process_tier1(integration, caldav_series(@href), [])

      occurrences = blocks_over_weeks(integration, first_start, 3)
      assert Enum.all?(occurrences, &(&1.uid != one_off.uid))
      assert length(occurrences) == 3
      assert Enum.reject(occurrences, &(&1.video_link == link)) == []
      assert Enum.reject(occurrences, &(&1.video_integration_id == video.id)) == []
    end

    # The booking's calendar copy can be given a repeat rule from the
    # calendar (a rule is no change of timing, `EditGuard.check/3`). The row
    # under its UID is then replaced by the occurrences, not deleted from the
    # calendar, so the booking must survive a full fetch, which prunes by
    # absence.
    test "a booking whose calendar copy was given a repeat rule is not cancelled by a full fetch",
         %{integration: integration, first_start: first_start} do
      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          calendar_uid: "weekly@tymeslot.com",
          start_time: first_start,
          end_time: DateTime.add(first_start, 3600)
        )

      insert_synced_caldav_one_off(integration, first_start, nil, nil)

      {:ok, _row} =
        ProviderCalendarEventQueries.apply_local_edit(integration.id, "weekly@tymeslot.com", %{
          recurrence_rule: "FREQ=WEEKLY;COUNT=3"
        })

      {range_start, range_end} = Sync.window()

      assert :ok =
               SyncReconciler.process_full_fetch(
                 integration,
                 caldav_series(@href),
                 range_start,
                 range_end,
                 Clock.utc_now(),
                 "/cal/"
               )

      assert blocks_on(integration, first_start) == ["weekly@tymeslot.com_20991118T180000"]
      assert Repo.reload!(meeting).status == meeting.status
      refute_enqueued(worker: EmailWorker)
    end

    # The rule was given while the provider failed, or a later edit was
    # queued: the row under the series' UID holds that change and stays for
    # the queue to send. The server returns only the series' occurrences, so a
    # full fetch must not read the row as gone, delete it and cancel the
    # booking linked to it.
    test "a booking copy holding a queued edit survives a full fetch, and so does the booking",
         %{integration: integration, first_start: first_start} do
      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          calendar_uid: "weekly@tymeslot.com",
          start_time: first_start,
          end_time: DateTime.add(first_start, 3600)
        )

      insert_synced_caldav_one_off(integration, first_start, nil, nil)

      {:ok, _row} =
        ProviderCalendarEventQueries.apply_local_edit(integration.id, "weekly@tymeslot.com", %{
          recurrence_rule: "FREQ=WEEKLY;COUNT=3"
        })

      set_sync_state(integration, "weekly@tymeslot.com", "locally_modified")

      {range_start, range_end} = Sync.window()

      assert :ok =
               SyncReconciler.process_full_fetch(
                 integration,
                 caldav_series(@href),
                 range_start,
                 range_end,
                 Clock.utc_now(),
                 "/cal/"
               )

      assert {:ok, %{sync_state: "locally_modified"}} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "weekly@tymeslot.com")

      assert Repo.reload!(meeting).status == :confirmed
      refute_enqueued(worker: EmailWorker)
    end

    test "a stand-in with a queued delete stays until the queue has sent it", %{
      integration: integration,
      first_start: first_start
    } do
      cache_created_caldav_series(integration, first_start, %{})
      set_sync_state(integration, "weekly@tymeslot.com", "locally_deleted")

      assert :ok = SyncReconciler.process_tier1(integration, caldav_series(@href), [])

      assert {:ok, %{sync_state: "locally_deleted"}} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "weekly@tymeslot.com")
    end

    # A create whose PUT timed out is queued, but landed: its occurrences
    # coming back from the server say so.
    test "a stand-in with a queued create goes once the server returns the series", %{
      integration: integration,
      first_start: first_start
    } do
      cache_created_caldav_series(integration, first_start, %{})
      set_sync_state(integration, "weekly@tymeslot.com", "locally_created")

      assert :ok = SyncReconciler.process_tier1(integration, caldav_series(@href), [])

      assert blocks_on(integration, first_start) == ["weekly@tymeslot.com_20991118T180000"]
    end
  end

  # A one-off CalDAV event under the series' future UID, as an earlier sync
  # cached it, before the organiser gave it a repeat rule.
  defp insert_synced_caldav_one_off(integration, first_start, video, link) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      uid: "weekly@tymeslot.com",
      provider: "caldav",
      provider_calendar_id: "/cal/",
      provider_event_id: @href,
      start_at: first_start,
      end_at: DateTime.add(first_start, 3600),
      synced_at: ~U[2099-11-01 00:00:00.000000Z],
      video_link: link,
      video_integration_id: video && video.id
    )
  end

  defp set_sync_state(integration, uid, state) do
    {1, _rows} =
      ProviderCalendarEventSchema
      |> where([e], e.calendar_integration_id == ^integration.id and e.uid == ^uid)
      |> Repo.update_all(set: [sync_state: state])
  end

  # The row the grid caches for a series it has just written to a CalDAV
  # calendar: the series' own UID, and the href the PUT addressed.
  defp cache_created_caldav_series(integration, first_start, extra) do
    :ok =
      Changes.cache_created_event(
        Map.merge(
          %{
            uid: "weekly@tymeslot.com",
            calendar_integration_id: integration.id,
            provider: "caldav",
            provider_calendar_id: "/cal/",
            provider_event_id: @href,
            summary: "Weekly review",
            all_day: false,
            start_at: first_start,
            end_at: DateTime.add(first_start, 3600),
            recurrence_rule: "FREQ=WEEKLY;COUNT=3"
          },
          extra
        )
      )
  end

  defp payload(integration, start_at, rule) do
    %{
      creating: %{
        title: "Weekly review",
        integration_id: integration.id,
        attendees: [],
        recurrence_rule: rule
      },
      start_at: start_at,
      end_at: DateTime.add(start_at, 3600),
      timezone: "Etc/UTC"
    }
  end

  defp sync_debug(integration),
    do:
      assert(
        :ok =
          perform_job(SyncDebugCalendarWorker, %{"calendar_integration_id" => integration.id})
      )

  # The uids of the blocks the calendar draws on the day `start` falls on.
  defp blocks_on(integration, start) do
    day_start = DateTime.new!(DateTime.to_date(start), ~T[00:00:00], "Etc/UTC")

    integration
    |> rows_between(day_start, DateTime.add(day_start, 1, :day))
    |> Enum.map(& &1.uid)
  end

  defp blocks_over_weeks(integration, start, weeks),
    do: rows_between(integration, start, DateTime.add(start, weeks * 7, :day))

  defp rows_between(integration, range_start, range_end),
    do: CalendarGrid.list_events_for_range([integration.id], range_start, range_end)

  # The key a CalDAV-family occurrence of a UTC series is cached under.
  defp stamp(%DateTime{} = start), do: Calendar.strftime(start, "%Y%m%dT%H%M%S")

  defp caldav_series(href) do
    {:ok, [raw]} =
      ICalParser.parse("""
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//EN
      BEGIN:VEVENT
      UID:weekly@tymeslot.com
      DTSTAMP:20991101T000000Z
      DTSTART:20991118T180000Z
      DTEND:20991118T190000Z
      RRULE:FREQ=WEEKLY;COUNT=3
      SUMMARY:Weekly review
      END:VEVENT
      END:VCALENDAR
      """)

    [Map.put(raw, :href, href)]
  end
end
