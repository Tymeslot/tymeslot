defmodule Tymeslot.CalendarGrid.SeriesPreviewTest do
  @moduledoc """
  A series written from the calendar is cached as one row until its next
  sync. Until then its later occurrences are previewed from that row, so
  every reader of the cache (the grid, the agenda, the free/busy feed, the
  desktop reminders) shows each week; the booking page reads each calendar
  live and blocks them already. Once a sync caches the occurrences, nothing
  is previewed and the row goes, on every provider, so no date ever shows
  the event twice.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Tymeslot.Test.ClockHelpers, only: [freeze_clock: 1]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.EventWindow
  alias Tymeslot.FreeBusy
  alias Tymeslot.Integrations.Calendar.CalDAV.SyncReconciler
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.DebugStore
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Workers.SyncDebugCalendarWorker
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @rule "FREQ=WEEKLY;COUNT=4"
  @first ~U[2026-11-18 18:00:00.000000Z]

  describe "a series created on the debug calendar, before any sync" do
    setup :debug_calendar

    setup %{user: user, integration: integration, first_start: first_start} do
      {:ok, %{event: series}} =
        Changes.create_event(user.id, payload(integration, first_start, @rule))

      %{series: series}
    end

    test "shows every week on the grid, the later ones previewed from the series", %{
      integration: integration,
      series: series,
      first_start: first_start
    } do
      events = weeks(integration, first_start, 4)

      assert Enum.map(events, & &1.start_at) == Enum.map(0..3, &week(first_start, &1))
      assert [%{preview_of: nil} | previews] = events
      assert Enum.reject(previews, &(&1.preview_of.id == series.id)) == []

      assert Enum.map(previews, & &1.preview_key) ==
               Enum.map(1..3, &stamp(week(first_start, &1)))
    end

    test "asks for the sync that brings the occurrences", %{integration: integration} do
      assert_enqueued(
        worker: SyncDebugCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "the booking page counts the later weeks as busy", %{
      user: user,
      first_start: first_start
    } do
      {:ok, busy} =
        CalendarEvents.get_events_for_range_fresh(
          user.id,
          DateTime.to_date(first_start),
          DateTime.to_date(week(first_start, 3))
        )

      busy_starts = MapSet.new(busy, &DateTime.to_unix(&1.start_time))

      for n <- 1..3,
          do: assert(MapSet.member?(busy_starts, DateTime.to_unix(week(first_start, n))))
    end

    test "the free/busy feed publishes the later weeks", %{user: user, first_start: first_start} do
      profile = insert(:profile, user: user, timezone: "Etc/UTC")

      intervals =
        Enum.map(
          FreeBusy.busy_intervals(profile, first_start, week(first_start, 4)),
          fn {start, _finish} -> DateTime.to_unix(start) end
        )

      assert Enum.sort(intervals) == Enum.map(0..3, &DateTime.to_unix(week(first_start, &1)))
    end

    test "each preview is drawn with an id of its own, waiting to sync", %{
      user: user,
      integration: integration,
      first_start: first_start
    } do
      [series_row | previews] = weeks(integration, first_start, 4)
      context = payload_context(user, integration)

      drawn = Enum.map(previews, &EventPayload.event(&1, context))

      ids = Enum.map([series_row | previews], &EventPayload.id/1)
      assert length(Enum.uniq(ids)) == 4
      assert Enum.reject(drawn, &(&1.preview and &1.attention and &1.editable)) == []
      assert Enum.filter(drawn, & &1.movable) == []
      refute EventPayload.event(series_row, context).preview
    end

    test "a change to one previewed occurrence is refused, saying the calendar is syncing",
         %{user: user, integration: integration, first_start: first_start} do
      [_series_row, preview | _rest] = weeks(integration, first_start, 4)

      assert EditGuard.check(user.id, [integration], preview) == {:error, :syncing}
      assert EditGuard.check_timing(user.id, [integration], preview) == {:error, :syncing}

      assert {:warning, "Syncing with your calendar" <> _rest} =
               CalendarEditMessages.refusal({:error, :syncing})
    end

    test "opening a preview opens the series", %{
      integration: integration,
      series: series,
      first_start: first_start
    } do
      [_series_row, preview | _rest] = weeks(integration, first_start, 4)

      assert CalendarGrid.preview_series(preview).id == series.id
      assert CalendarGrid.preview_series(preview).start_at == series.start_at
    end

    test "after the sync each date shows one block and nothing is previewed", %{
      integration: integration,
      first_start: first_start
    } do
      perform_job(SyncDebugCalendarWorker, %{"calendar_integration_id" => integration.id})

      events = weeks(integration, first_start, 4)

      assert Enum.map(events, & &1.start_at) == Enum.map(0..3, &week(first_start, &1))
      assert Enum.reject(events, &is_nil(&1.preview_of)) == []
    end
  end

  describe "a series with a reminder on the debug calendar, before any sync" do
    setup :debug_calendar

    test "reminds of the later occurrences too", %{
      user: user,
      integration: integration,
      first_start: first_start
    } do
      reminder = %{method: "popup", minutes_before: 10}

      {:ok, _created} =
        Changes.create_event(
          user.id,
          put_in(
            payload(integration, first_start, "FREQ=DAILY;COUNT=3"),
            [:creating, :reminders],
            [reminder]
          )
        )

      starts =
        [integration.id]
        |> CalendarGrid.list_upcoming_events_with_reminders(DateTime.utc_now(), [integration])
        |> Enum.map(& &1.start_at)

      assert starts == Enum.map(0..2, &DateTime.add(first_start, &1, :day))
    end
  end

  describe "an event given a repeat rule on the debug calendar" do
    setup :debug_calendar

    test "previews its later weeks and asks for a sync", %{
      user: user,
      integration: integration,
      first_start: first_start
    } do
      {:ok, %{event: one_off}} =
        Changes.create_event(user.id, payload(integration, first_start, nil))

      perform_job(SyncDebugCalendarWorker, %{"calendar_integration_id" => integration.id})

      {:ok, _updated} =
        Changes.update_event(user.id, one_off, %{recurrence_rule: @rule}, timezone: "Etc/UTC")

      assert Enum.map(weeks(integration, first_start, 4), & &1.start_at) ==
               Enum.map(0..3, &week(first_start, &1))

      assert_enqueued(
        worker: SyncDebugCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end
  end

  describe "a series on a CalDAV calendar" do
    setup do
      freeze_clock(~U[2026-11-10 12:00:00Z])
      integration = insert(:calendar_integration, provider: "caldav", calendar_paths: ["/cal/"])

      stand_in(integration, %{
        uid: "weekly@tymeslot.com",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/weekly@tymeslot.com.ics"
      })

      %{integration: integration}
    end

    test "is previewed until a delta sync caches its occurrences, then shown once a date", %{
      integration: integration
    } do
      assert length(previews(weeks(integration, @first, 4))) == 3

      assert :ok = SyncReconciler.process_tier1(integration, caldav_series(), [])

      events = weeks(integration, @first, 4)
      assert Enum.map(events, & &1.start_at) == Enum.map(0..3, &week(@first, &1))
      assert previews(events) == []
    end
  end

  describe "a series written across a change of the clocks" do
    setup do
      freeze_clock(~U[2026-10-10 12:00:00Z])
      integration = insert(:calendar_integration, provider: "caldav", calendar_paths: ["/cal/"])
      %{integration: integration}
    end

    # Mondays at 09:00 in Warsaw: 07:00 UTC until the clocks go back on 25
    # October, 08:00 UTC after.
    test "is previewed on the wall clock the sync caches it on", %{integration: integration} do
      first = ~U[2026-10-19 07:00:00.000000Z]

      stand_in(integration, %{
        uid: "standup@tymeslot.com",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/standup@tymeslot.com.ics",
        start_at: first,
        end_at: DateTime.add(first, 900),
        timezone: "Europe/Warsaw"
      })

      previewed = integration |> weeks(first, 4) |> previews() |> Enum.map(& &1.start_at)

      assert :ok =
               SyncReconciler.process_tier1(
                 integration,
                 caldav_document("standup@tymeslot.com", """
                 DTSTART;TZID=Europe/Warsaw:20261019T090000
                 DTEND;TZID=Europe/Warsaw:20261019T091500
                 """),
                 []
               )

      [_first | synced] = integration |> weeks(first, 4) |> Enum.map(& &1.start_at)

      assert previewed == synced
      assert hd(previewed) == ~U[2026-10-26 08:00:00.000000Z]
    end
  end

  describe "a booking whose calendar copy was given a repeat rule" do
    setup do
      freeze_clock(~U[2026-11-10 12:00:00Z])
      :ok
    end

    test "is drawn as the booking on its date, with the later weeks previewed" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "google")

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          calendar_integration_id: integration.id,
          calendar_uid: "weekly-ical-uid",
          start_time: @first,
          end_time: DateTime.add(@first, 3600)
        )

      stand_in(integration, %{
        uid: "weekly-ical-uid",
        provider: "google",
        provider_calendar_id: "primary",
        provider_event_id: "master-1"
      })

      {range_start, range_end} = {DateTime.add(@first, -1, :hour), week(@first, 4)}
      events = EventWindow.list_events(user.id, [integration], range_start, range_end)

      assert [%{kind: :booking, meeting_id: meeting_id}] =
               Enum.filter(events, &(Map.get(&1, :kind) == :booking))

      assert meeting_id == meeting.id
      assert events |> previews() |> Enum.map(& &1.start_at) == Enum.map(1..3, &week(@first, &1))
      assert length(events) == 4
    end

    # After the sync the copy's own date is an occurrence cached under the
    # series' UID and the slot's key, and under the series' href, neither of
    # which the booking carries: a CalDAV booking knows its copy by the bare
    # UID alone.
    test "on CalDAV is drawn once on its date after the sync, beside the later weeks" do
      user = insert(:user)

      integration =
        insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          calendar_integration_id: integration.id,
          calendar_uid: "weekly@tymeslot.com",
          start_time: @first,
          end_time: DateTime.add(@first, 3600)
        )

      stand_in(integration, %{
        uid: "weekly@tymeslot.com",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/weekly@tymeslot.com.ics"
      })

      assert :ok = SyncReconciler.process_tier1(integration, caldav_series(), [])

      {range_start, range_end} = {DateTime.add(@first, -1, :hour), week(@first, 4)}
      events = EventWindow.list_events(user.id, [integration], range_start, range_end)

      assert [%{meeting_id: meeting_id, copy: copy}] =
               Enum.filter(events, &(Map.get(&1, :kind) == :booking))

      assert meeting_id == meeting.id
      assert copy.calendar_integration_id == integration.id

      assert events |> Enum.reject(&(Map.get(&1, :kind) == :booking)) |> Enum.map(& &1.uid) ==
               Enum.map(1..3, &("weekly@tymeslot.com_" <> stamp(week(@first, &1))))
    end
  end

  describe "the occurrences previewed" do
    setup do
      freeze_clock(~U[2026-11-10 12:00:00Z])
      %{integration: insert(:calendar_integration, provider: "google")}
    end

    test "end with a COUNT", %{integration: integration} do
      google_stand_in(integration, %{recurrence_rule: "FREQ=WEEKLY;COUNT=3"})

      assert starts(previews(weeks(integration, @first, 6))) ==
               Enum.map(1..2, &week(@first, &1))
    end

    test "end with an UNTIL, and none fall in a window after the last", %{
      integration: integration
    } do
      google_stand_in(integration, %{recurrence_rule: "FREQ=WEEKLY;UNTIL=20261202T235959Z"})

      assert starts(previews(weeks(integration, @first, 6))) ==
               Enum.map(1..2, &week(@first, &1))

      assert weeks(integration, week(@first, 3), 3) == []
    end

    test "leave out an excluded date", %{integration: integration} do
      google_stand_in(integration, %{recurrence_exceptions: [~D[2026-11-25]]})

      assert starts(previews(weeks(integration, @first, 4))) ==
               Enum.map(2..3, &week(@first, &1))
    end

    test "of an all-day series fall on whole days", %{integration: integration} do
      google_stand_in(integration, %{
        all_day: true,
        start_at: nil,
        end_at: nil,
        start_date: ~D[2026-11-18],
        end_date: ~D[2026-11-19],
        recurrence_rule: "FREQ=WEEKLY;COUNT=3"
      })

      assert integration
             |> weeks(@first, 4)
             |> previews()
             |> Enum.map(&{&1.start_date, &1.end_date}) ==
               [{~D[2026-11-25], ~D[2026-11-26]}, {~D[2026-12-02], ~D[2026-12-03]}]
    end

    test "count towards a read's limit, the earliest kept", %{integration: integration} do
      google_stand_in(integration, %{})

      events =
        CalendarGrid.list_events_for_range(
          [integration.id],
          DateTime.add(@first, -1, :hour),
          week(@first, 4),
          limit: 2
        )

      assert starts(events) == [@first, week(@first, 1)]
    end
  end

  describe "a Google or Outlook one-off given a repeat rule" do
    setup do
      freeze_clock(~U[2026-11-10 12:00:00Z])
      Mox.stub(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context -> :ok end)
      :ok
    end

    for provider <- ["google", "outlook"] do
      test "on #{provider} previews its later weeks" do
        provider = unquote(provider)
        user = insert(:user)
        integration = insert(:calendar_integration, user: user, provider: provider)

        one_off =
          insert(:provider_calendar_event,
            calendar_integration: integration,
            uid: "one-off-ical-uid",
            provider: provider,
            provider_calendar_id: "primary",
            provider_event_id: "one-off-1",
            summary: "Weekly review",
            start_at: @first,
            end_at: DateTime.add(@first, 3600)
          )

        assert previews(weeks(integration, @first, 4)) == []

        {:ok, _updated} =
          Changes.update_event(user.id, one_off, %{recurrence_rule: @rule}, timezone: "Etc/UTC")

        assert starts(weeks(integration, @first, 4)) == Enum.map(0..3, &week(@first, &1))
      end
    end
  end

  describe "a series on Google or Outlook" do
    setup do
      freeze_clock(~U[2026-11-10 12:00:00Z])
      :ok
    end

    for provider <- ["google", "outlook"] do
      test "on #{provider} is previewed until its occurrences are cached, then shown once a date" do
        provider = unquote(provider)
        integration = insert(:calendar_integration, provider: provider)

        stand_in(integration, %{
          uid: "weekly-ical-uid",
          provider: provider,
          provider_calendar_id: "primary",
          provider_event_id: "master-1"
        })

        assert length(previews(weeks(integration, @first, 4))) == 3

        occurrences =
          for n <- 0..3 do
            start = week(@first, n)

            CalendarEvent.new!(%{
              uid: "master-1_#{Calendar.strftime(start, "%Y%m%dT%H%M%SZ")}",
              provider: String.to_existing_atom(provider),
              calendar_integration_id: integration.id,
              provider_calendar_id: "primary",
              provider_event_id: "master-1_#{n}",
              recurring_event_id: "master-1",
              summary: "Weekly review",
              all_day: false,
              start_at: start,
              end_at: DateTime.add(start, 3600),
              synced_at: DateTime.utc_now()
            })
          end

        assert {:ok, _count} = Sync.upsert_cache(integration, occurrences)

        events = weeks(integration, @first, 4)
        assert Enum.map(events, & &1.start_at) == Enum.map(0..3, &week(@first, &1))
        assert previews(events) == []
      end
    end
  end

  defp debug_calendar(_context) do
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

    first_start =
      DateTime.utc_now()
      |> DateTime.to_date()
      |> Date.add(1)
      |> DateTime.new!(~T[18:00:00.000000], "Etc/UTC")

    %{user: user, integration: integration, first_start: first_start}
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

  # The row the calendar caches for a series it has just written.
  defp stand_in(integration, attrs) do
    :ok =
      Changes.cache_created_event(
        Map.merge(
          %{
            calendar_integration_id: integration.id,
            summary: "Weekly review",
            all_day: false,
            start_at: @first,
            end_at: DateTime.add(@first, 3600),
            recurrence_rule: @rule,
            timezone: "Etc/UTC"
          },
          attrs
        )
      )
  end

  defp google_stand_in(integration, attrs) do
    stand_in(
      integration,
      Map.merge(
        %{
          uid: "weekly-ical-uid",
          provider: "google",
          provider_calendar_id: "primary",
          provider_event_id: "master-1"
        },
        attrs
      )
    )
  end

  defp starts(events), do: Enum.map(events, & &1.start_at)

  defp weeks(integration, start, count),
    do:
      CalendarGrid.list_events_for_range(
        [integration.id],
        DateTime.add(start, -1, :hour),
        DateTime.add(start, count * 7, :day)
      )

  defp previews(events), do: Enum.filter(events, &CalendarGrid.preview?/1)

  defp week(start, n), do: DateTime.add(start, n * 7, :day)

  defp stamp(%DateTime{} = start), do: Calendar.strftime(start, "%Y%m%dT%H%M%S")

  defp payload_context(user, integration),
    do: %{
      timezone: "Etc/UTC",
      integration_tokens: %{},
      calendar_tokens: %{},
      integrations: [integration],
      user_id: user.id
    }

  defp caldav_document(uid, timing) do
    {:ok, [raw]} =
      ICalParser.parse("""
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//EN
      BEGIN:VEVENT
      UID:#{uid}
      DTSTAMP:20261001T000000Z
      #{String.trim(timing)}
      RRULE:#{@rule}
      SUMMARY:Standup
      END:VEVENT
      END:VCALENDAR
      """)

    [Map.put(raw, :href, "/cal/#{uid}.ics")]
  end

  defp caldav_series do
    {:ok, [raw]} =
      ICalParser.parse("""
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//EN
      BEGIN:VEVENT
      UID:weekly@tymeslot.com
      DTSTAMP:20261101T000000Z
      DTSTART:20261118T180000Z
      DTEND:20261118T190000Z
      RRULE:#{@rule}
      SUMMARY:Weekly review
      END:VEVENT
      END:VCALENDAR
      """)

    [Map.put(raw, :href, "/cal/weekly@tymeslot.com.ics")]
  end
end
