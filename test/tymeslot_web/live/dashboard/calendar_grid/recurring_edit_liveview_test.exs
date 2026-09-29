defmodule TymeslotWeb.Dashboard.CalendarGrid.RecurringEditLiveViewTest do
  @moduledoc """
  Editing one occurrence of a repeating event from the grid: dragging it,
  resizing it, re-dating it, renaming it.

  On the CalDAV family the sync expands a series into one cached row per
  occurrence, all sharing the series' href. A change of time of one of them
  asks which occurrences it applies to, as it does on Google and Outlook;
  "This event" writes it as that occurrence's override in the series'
  resource, and the occurrence keeps its edit. A field edit, such as a
  rename, asks nothing and is written to the occurrence alone. Turning one
  occurrence all-day is refused by the domain, and the grid reverts it and
  says why.

  An Exchange occurrence takes no scope, so it is written as that event
  alone, without the prompt. `RecurringScopeLiveViewTest` follows each
  choice down to the wire.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup :verify_on_exit!

  # The provider write runs in a Task; allow for a busy test machine.
  @task_timeout 5_000

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)

    integration =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    {:ok, conn: conn, user: user, integration: integration}
  end

  describe "dragging one occurrence of a CalDAV series" do
    test "writes it to the occurrence, and the occurrence keeps its new time", %{
      conn: conn,
      integration: integration
    } do
      event = insert_occurrence(integration)
      stub_update({:ok, %{document: "NEW DOCUMENT"}})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      drop(lv, event, 14)
      confirm_scope(lv, "this_only")

      assert {:update, payload} = await_update(lv)
      assert payload.occurrence.key == key_for(event)
      assert payload.occurrence.scope == :this_only
      assert DateTime.compare(payload.occurrence.changes.start_time, at_today(14)) == :eq

      refute render(lv) =~ "recurrence-prompt-modal"

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert DateTime.compare(row.start_at, at_today(14)) == :eq
      assert row.raw_ical == "NEW DOCUMENT"
    end

    test "writes an occurrence already edited on its own to its own override", %{
      conn: conn,
      integration: integration
    } do
      # A detached override: no RRULE of its own, named only by the recurrence
      # id the sync keeps in `provider_metadata`.
      event =
        insert_occurrence(integration, %{
          recurrence_rule: nil,
          provider_metadata: %{"uid" => "weekly-standup", "recurrence_id" => "20260915T090000"}
        })

      stub_update({:ok, %{document: "NEW DOCUMENT"}})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      drop(lv, event, 14)
      confirm_scope(lv, "this_only")

      assert {:update, %{occurrence: occurrence}} = await_update(lv)
      assert occurrence.key == key_for(event)
    end

    test "resizing it writes the occurrence's new end", %{conn: conn, integration: integration} do
      event = insert_occurrence(integration)
      stub_update({:ok, %{document: "NEW DOCUMENT"}})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("event_resized", %{
        "event-id" => to_string(event.id),
        "event-date" => Date.to_iso8601(Date.utc_today()),
        "new-end-hour" => "13",
        "new-end-minute" => "0"
      })

      confirm_scope(lv, "this_only")

      assert {:update, %{occurrence: occurrence}} = await_update(lv)
      assert DateTime.compare(occurrence.changes.end_time, at_today(13)) == :eq

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert DateTime.compare(row.end_at, at_today(13)) == :eq
    end

    test "turning it into an all-day event is refused, reverted and explained", %{
      conn: conn,
      integration: integration
    } do
      event = insert_occurrence(integration)
      # A write that reached the calendar would report itself here.
      stub_update({:ok, %{document: "NEW DOCUMENT"}})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("show_event", %{"event-id" => to_string(event.id)})

      lv |> element("#calendar-grid") |> render_hook("toggle_event_all_day", %{})

      eventually(
        fn ->
          assert render(lv) =~
                   "Events of a repeating series cannot be switched between all-day and timed here."
        end,
        timeout: @task_timeout
      )

      refute render(lv) =~ "Failed to update event - changes reverted"

      refute_received {:provider_call, _task_pid, _call}

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      refute row.all_day
    end
  end

  describe "renaming one occurrence of a CalDAV series" do
    test "writes it to the occurrence, which keeps its new title", %{
      conn: conn,
      integration: integration
    } do
      event = insert_occurrence(integration)
      stub_update({:ok, %{document: "NEW DOCUMENT"}})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("show_event", %{"event-id" => to_string(event.id)})

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Daily standup"})

      assert {:update, %{occurrence: occurrence}} = await_update(lv)
      assert occurrence.changes.summary == "Daily standup"

      html = render(lv)
      assert html =~ "Daily standup"
      refute html =~ "Recurring events cannot be edited here yet."

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.summary == "Daily standup"
    end
  end

  describe "dragging an event the writer can address on its own" do
    test "a one-off CalDAV event still moves", %{conn: conn, integration: integration} do
      event = insert_event(integration)
      stub_update()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      drop(lv, event, 14)

      assert {:update, payload} = await_update(lv)
      assert DateTime.compare(payload.start_time, at_today(14)) == :eq
      refute render(lv) =~ "Recurring events cannot be edited here yet."

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert DateTime.compare(row.start_at, at_today(14)) == :eq
    end

    test "a Google occurrence is offered the recurrence prompt instead", %{
      conn: conn,
      user: user
    } do
      google = insert(:calendar_integration, user: user, provider: "google")

      event =
        insert_event(google, %{
          provider: "google",
          provider_calendar_id: "primary",
          recurring_event_id: "weekly-standup",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      drop(lv, event, 14)

      html = render(lv)
      assert html =~ "recurrence-prompt-modal"
      assert html =~ "the rest of the series stays as it is"
      refute html =~ "Recurring events cannot be edited here yet."
    end

    test "an Exchange occurrence is written as that event alone, without the prompt", %{
      conn: conn,
      user: user
    } do
      exchange = insert(:calendar_integration, user: user, provider: "exchange")

      # An Exchange occurrence names no master; only its item type says it
      # belongs to a series.
      event =
        insert_event(exchange, %{
          provider: "exchange",
          provider_calendar_id: "calendar",
          provider_event_id: "AAMkAD-occurrence",
          provider_metadata: %{"calendar_item_type" => "Occurrence"}
        })

      stub_update()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      drop(lv, event, 14)

      assert {:update, payload} = await_update(lv)
      refute Map.has_key?(payload, :occurrence)
      assert DateTime.compare(payload.start_time, at_today(14)) == :eq
      refute render(lv) =~ "recurrence-prompt-modal"

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(exchange.id, event.uid)
      assert DateTime.compare(row.start_at, at_today(14)) == :eq
    end
  end

  defp at_today(hour), do: DateTime.new!(Date.utc_today(), Time.new!(hour, 0, 0), "Etc/UTC")

  defp insert_event(integration, attrs \\ %{}) do
    today = Date.utc_today()

    defaults = %{
      calendar_integration: integration,
      provider: "caldav",
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/weekly-standup-#{System.unique_integer([:positive])}.ics",
      summary: "Weekly standup",
      start_at: DateTime.new!(today, ~T[09:00:00], "Etc/UTC"),
      end_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
      all_day: false,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  # An occurrence of a weekly series, expanded by the sync: its uid is the
  # series' UID and the occurrence's key.
  defp insert_occurrence(integration, attrs \\ %{}) do
    key = Calendar.strftime(Date.utc_today(), "%Y%m%dT090000")

    insert_event(
      integration,
      Map.merge(
        %{
          uid: "weekly-standup_#{key}",
          provider_event_id: "/cal/weekly-standup.ics",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
          timezone: "Etc/UTC",
          provider_metadata: %{"uid" => "weekly-standup"},
          raw_ical: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n",
          etag: "\"etag-1\""
        },
        attrs
      )
    )
  end

  defp key_for(event), do: String.replace_prefix(event.uid, "weekly-standup_", "")

  # Drops the event on today's grid at `hour`, keeping its one-hour length.
  defp drop(lv, event, hour) do
    lv
    |> element("#calendar-grid")
    |> render_hook("event_dropped", %{
      "event-id" => to_string(event.id),
      "new-date" => Date.to_iso8601(Date.utc_today()),
      "new-hour" => to_string(hour),
      "new-minute" => "0",
      "new-end-hour" => to_string(hour + 1),
      "new-end-minute" => "0"
    })
  end

  defp confirm_scope(lv, scope) do
    lv
    |> element("#recurrence-prompt-modal [phx-value-scope='#{scope}']")
    |> render_click()
  end

  defp stub_update(result \\ :ok) do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:provider_call, self(), {:update, payload}})
      result
    end)
  end

  # Waits for the provider call, for the Task that made it to exit, and then
  # renders so the LiveView handles the Task's result.
  defp await_update(lv) do
    assert_receive {:provider_call, task_pid, call}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    call
  end
end
