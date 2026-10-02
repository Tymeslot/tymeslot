defmodule Tymeslot.CalendarGrid.IcsImportTest do
  @moduledoc """
  Covers importing an uploaded `.ics` file into a calendar: what `plan/1`
  reads out of a file, which calendars `target/3` accepts, what `run/3`
  writes to the provider, and the side effects `CalendarGrid.import_ics/5`
  adds on top (availability dropped, the calendar synced).
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.IcsImport
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  setup :verify_on_exit!

  defp ics(vevents) do
    Enum.join(
      ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Test//EN"] ++ vevents ++ ["END:VCALENDAR"],
      "\r\n"
    )
  end

  defp vevent(lines), do: Enum.join(["BEGIN:VEVENT"] ++ lines ++ ["END:VEVENT"], "\r\n")

  defp timed(uid, summary, start, finish, extra \\ []) do
    vevent(["UID:#{uid}", "SUMMARY:#{summary}", "DTSTART:#{start}", "DTEND:#{finish}"] ++ extra)
  end

  defp plan!(content) do
    {:ok, plan} = IcsImport.plan(content)
    plan
  end

  describe "plan/1" do
    test "reads a timed event's title, place, description and UTC timing" do
      plan =
        plan!(
          ics([
            timed("a@x", "Dentist", "20261105T090000Z", "20261105T093000Z", [
              "LOCATION:High Street 4",
              "DESCRIPTION:Bring the forms"
            ])
          ])
        )

      assert [event] = plan.events
      assert event.summary == "Dentist"
      assert event.location == "High Street 4"
      assert event.description == "Bring the forms"
      assert event.start_time == ~U[2026-11-05 09:00:00Z]
      assert event.end_time == ~U[2026-11-05 09:30:00Z]
      assert event.all_day == false
      assert plan.series == 0
    end

    test "reads a DATE-valued event as all-day with its exclusive end date" do
      plan =
        plan!(
          ics([
            vevent([
              "UID:holiday@x",
              "SUMMARY:Holiday",
              "DTSTART;VALUE=DATE:20261224",
              "DTEND;VALUE=DATE:20261227"
            ])
          ])
        )

      assert [%{all_day: true, start_time: ~D[2026-12-24], end_time: ~D[2026-12-27]}] =
               plan.events
    end

    test "drops organiser and attendees so the import invites nobody" do
      plan =
        plan!(
          ics([
            timed("m@x", "Planning", "20261105T090000Z", "20261105T100000Z", [
              "ORGANIZER;CN=Boss:mailto:boss@example.com",
              "ATTENDEE;CN=Ada:mailto:ada@example.com"
            ])
          ])
        )

      assert [event] = plan.events
      refute Map.has_key?(event, :attendees)
      refute Map.has_key?(event, :organizer)
    end

    test "keeps a free event free" do
      plan =
        plan!(
          ics([
            timed("f@x", "Focus", "20261105T090000Z", "20261105T100000Z", ["TRANSP:TRANSPARENT"])
          ])
        )

      assert [%{transparency: :transparent}] = plan.events
    end

    test "leaves cancelled events out and counts them" do
      plan =
        plan!(
          ics([
            timed("keep@x", "Kept", "20261105T090000Z", "20261105T100000Z"),
            timed("gone@x", "Gone", "20261106T090000Z", "20261106T100000Z", ["STATUS:CANCELLED"])
          ])
        )

      assert Enum.map(plan.events, & &1.summary) == ["Kept"]
      assert plan.cancelled == 1
    end

    test "excludes a series' EXDATEs and moved occurrences, writing each move on its own" do
      plan =
        plan!(
          ics([
            timed("weekly@x", "Standup", "20261102T090000Z", "20261102T091500Z", [
              "RRULE:FREQ=WEEKLY;COUNT=10",
              "EXDATE:20261109T090000Z"
            ]),
            # The 16 November occurrence moved an hour later.
            timed("weekly@x", "Standup (late)", "20261116T100000Z", "20261116T101500Z", [
              "RECURRENCE-ID:20261116T090000Z"
            ]),
            # The 23 November occurrence was cancelled.
            timed("weekly@x", "Standup", "20261123T090000Z", "20261123T091500Z", [
              "RECURRENCE-ID:20261123T090000Z",
              "STATUS:CANCELLED"
            ])
          ])
        )

      assert [series, moved] = plan.events
      assert series.recurrence_rule =~ "FREQ=WEEKLY"

      assert Enum.sort(series.recurrence_exceptions, DateTime) == [
               ~U[2026-11-09 09:00:00Z],
               ~U[2026-11-16 09:00:00Z],
               ~U[2026-11-23 09:00:00Z]
             ]

      assert moved.summary == "Standup (late)"
      assert moved.start_time == ~U[2026-11-16 10:00:00Z]
      refute Map.has_key?(moved, :recurrence_rule)
      assert plan.series == 1
    end

    test "reads a wall-clock RECURRENCE-ID in the series' own zone" do
      plan =
        plan!(
          ics([
            vevent([
              "UID:berlin@x",
              "SUMMARY:Yoga",
              "DTSTART;TZID=Europe/Berlin:20260706T180000",
              "DTEND;TZID=Europe/Berlin:20260706T190000",
              "RRULE:FREQ=WEEKLY;COUNT=4"
            ]),
            vevent([
              "UID:berlin@x",
              "SUMMARY:Yoga",
              "RECURRENCE-ID;TZID=Europe/Berlin:20260713T180000",
              "DTSTART;TZID=Europe/Berlin:20260713T190000",
              "DTEND;TZID=Europe/Berlin:20260713T200000"
            ])
          ])
        )

      assert [series, _moved] = plan.events
      # 18:00 in Berlin summer time is 16:00 UTC.
      assert series.recurrence_exceptions == [~U[2026-07-13 16:00:00Z]]
    end

    test "accepts a file starting with a byte-order mark" do
      content =
        <<0xEF, 0xBB, 0xBF>> <> ics([timed("b@x", "BOM", "20261105T090000Z", "20261105T100000Z")])

      assert {:ok, %{events: [%{summary: "BOM"}]}} = IcsImport.plan(content)
    end

    test "rejects content that is not a calendar" do
      assert IcsImport.plan("just some text") == {:error, :invalid_file}
      assert IcsImport.plan(<<0xFF, 0xFE, 0x00>>) == {:error, :invalid_file}
    end

    test "rejects a calendar with nothing to import" do
      assert IcsImport.plan(ics([])) == {:error, :no_events}

      only_cancelled =
        ics([timed("c@x", "Off", "20261105T090000Z", "20261105T100000Z", ["STATUS:CANCELLED"])])

      assert IcsImport.plan(only_cancelled) == {:error, :no_events}
    end

    test "rejects a file over the size cap" do
      assert IcsImport.plan(:binary.copy("x", IcsImport.max_bytes() + 1)) == {:error, :too_large}
    end

    test "rejects a file with more events than one import writes" do
      events =
        for n <- 0..IcsImport.max_events(),
            do: timed("e#{n}@x", "E#{n}", "20261105T090000Z", "20261105T100000Z")

      assert IcsImport.plan(ics(events)) == {:error, :too_many_events}
    end
  end

  describe "target/3" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "accepts the user's own writable calendar", %{user: user} do
      integration = insert(:calendar_integration, user: user, calendar_list: calendars())

      assert {:ok, %{integration: %{id: id}, calendar_id: "/cal/home/"}} =
               IcsImport.target(user.id, integration.id, "/cal/home/")

      assert id == integration.id
    end

    test "accepts no calendar for an integration whose calendars are undiscovered", %{user: user} do
      integration = insert(:calendar_integration, user: user, calendar_list: [])

      assert {:ok, %{calendar_id: nil}} = IcsImport.target(user.id, integration.id, nil)
    end

    test "refuses another user's integration", %{user: user} do
      other = insert(:calendar_integration, user: insert(:user))

      assert IcsImport.target(user.id, other.id, nil) == {:error, :not_found}
    end

    test "refuses an inactive integration", %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: false)

      assert IcsImport.target(user.id, integration.id, nil) == {:error, :not_found}
    end

    test "refuses a subscribed feed, which is read-only", %{user: user} do
      feed = insert(:calendar_integration, user: user, provider: "ics_url")

      assert IcsImport.target(user.id, feed.id, nil) == {:error, :not_found}
    end

    test "refuses a calendar that is read-only or not the integration's", %{user: user} do
      integration = insert(:calendar_integration, user: user, calendar_list: calendars())

      assert IcsImport.target(user.id, integration.id, "/cal/holidays/") == {:error, :not_found}
      assert IcsImport.target(user.id, integration.id, "/cal/elsewhere/") == {:error, :not_found}
      assert IcsImport.target(user.id, integration.id, nil) == {:error, :not_found}
    end
  end

  describe "run/3" do
    setup do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, calendar_list: calendars())
      {:ok, target} = IcsImport.target(user.id, integration.id, "/cal/home/")

      plan =
        plan!(
          ics([
            timed("one@x", "One", "20261105T090000Z", "20261105T100000Z", [
              "ATTENDEE:mailto:ada@example.com"
            ]),
            timed("two@x", "Two", "20261106T090000Z", "20261106T100000Z")
          ])
        )

      %{user: user, integration: integration, target: target, plan: plan}
    end

    test "writes every event to the chosen calendar under a fresh UID", ctx do
      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, 2, fn data, context ->
        send(test_pid, {:written, data, context})
        {:ok, CreatedEvent.new(data.uid)}
      end)

      assert %{total: 2, created: 2, failed: 0, halted: nil} = IcsImport.run(ctx.target, ctx.plan)

      assert_received {:written, %{summary: "One"} = one, {integration_id, user_id}}
      assert_received {:written, %{summary: "Two"} = two, _context}

      assert integration_id == ctx.integration.id
      assert user_id == ctx.user.id
      assert one.calendar_id == "/cal/home/"
      assert one.calendar_integration_id == ctx.integration.id
      refute one.uid in ["one@x", two.uid]
      refute Map.has_key?(one, :attendees)
    end

    test "counts a failed write and carries on with the rest", ctx do
      expect(Tymeslot.CalendarMock, :create_event, 2, fn
        %{summary: "One"}, _context -> {:error, :network_error}
        data, _context -> {:ok, CreatedEvent.new(data.uid)}
      end)

      assert %{created: 1, failed: 1, failed_titles: ["One"], halted: nil} =
               IcsImport.run(ctx.target, ctx.plan)
    end

    test "stops when the provider refuses the credentials", ctx do
      expect(Tymeslot.CalendarMock, :create_event, 1, fn _data, _context ->
        {:error, :unauthorized}
      end)

      assert %{created: 0, failed: 1, halted: :unauthorized} = IcsImport.run(ctx.target, ctx.plan)
    end

    test "reports progress after each event", ctx do
      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn data, _context ->
        {:ok, CreatedEvent.new(data.uid)}
      end)

      IcsImport.run(ctx.target, ctx.plan, on_progress: &send(test_pid, {:progress, &1}))

      assert_received {:progress, 1}
      assert_received {:progress, 2}
    end

    test "passes a series' exclusions to the provider, and counts them dropped on Outlook", ctx do
      plan =
        plan!(
          ics([
            timed("s@x", "Series", "20261102T090000Z", "20261102T100000Z", [
              "RRULE:FREQ=DAILY;COUNT=5",
              "EXDATE:20261103T090000Z"
            ])
          ])
        )

      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn data, _context ->
        send(test_pid, {:exceptions, data.recurrence_exceptions})
        {:ok, CreatedEvent.new(data.uid)}
      end)

      assert %{exclusions_dropped: 0} = IcsImport.run(ctx.target, plan)
      assert_received {:exceptions, [~U[2026-11-03 09:00:00Z]]}

      outlook = insert(:calendar_integration, user: ctx.user, provider: "outlook")
      {:ok, outlook_target} = IcsImport.target(ctx.user.id, outlook.id, nil)

      assert %{exclusions_dropped: 1} = IcsImport.run(outlook_target, plan)
    end
  end

  describe "CalendarGrid.import_ics/5" do
    setup do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, calendar_list: [])

      plan = plan!(ics([timed("one@x", "One", "20261105T090000Z", "20261105T100000Z")]))
      %{user: user, integration: integration, plan: plan}
    end

    test "drops the user's cached availability and syncs the calendar", ctx do
      AvailabilityCache.clear_all()
      key = AvailabilityCache.booking_window_events_key(ctx.user.id)
      :ok = AvailabilityCache.put(key, :cached)

      expect(Tymeslot.CalendarMock, :create_event, fn data, _context ->
        {:ok, CreatedEvent.new(data.uid)}
      end)

      assert {:ok, %{created: 1}} =
               CalendarGrid.import_ics(ctx.user.id, ctx.integration.id, nil, ctx.plan)

      assert AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :recomputed

      assert_enqueued(
        worker: SyncCalDavCalendarWorker,
        args: %{"calendar_integration_id" => ctx.integration.id}
      )
    end

    test "writes nothing to a calendar the user does not own", ctx do
      other = insert(:calendar_integration, user: insert(:user))

      assert CalendarGrid.import_ics(ctx.user.id, other.id, nil, ctx.plan) == {:error, :not_found}
      refute_enqueued(worker: SyncCalDavCalendarWorker)
    end
  end

  defp calendars do
    [
      %{id: "/cal/home/", path: "/cal/home/", name: "Home", selected: true},
      %{
        id: "/cal/holidays/",
        path: "/cal/holidays/",
        name: "Holidays",
        selected: true,
        read_only: true
      }
    ]
  end
end
