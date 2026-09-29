defmodule TymeslotWeb.Dashboard.CalendarGrid.SeriesHoldLiveViewTest do
  @moduledoc """
  Edits of the events of a recurring series while the whole series is
  being written ("All events") or moved to another calendar, end to end on
  a CalDAV series.

  Such an edit is held, not written: when the series write or move
  succeeds it is dropped and reported, and when it fails it is made. A
  write to the whole series, or a move, is refused while an edit of
  another of its events is still saving. Events outside the series are
  never held (see `TymeslotWeb.Dashboard.CalendarGrid.EventWrites`).

  As in `RecurringScopeLiveViewTest` and `SeriesMoveLiveViewTest`, only the
  HTTP client is mocked, and it holds the series' writes until the test
  releases them.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually

  alias Plug.Test
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup :set_mox_global
  setup :verify_on_exit!

  # The provider writes run in a Task; allow for a busy test machine.
  @task_timeout 5_000

  @source_base "https://source.example.org"
  @destination_base "https://dest.example.net"
  @series_url @source_base <> "/cal/standup.ics"
  @single_url @source_base <> "/cal/lunch.ics"

  setup %{conn: conn} do
    previous = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tymeslot, :calendar_module, previous),
        else: Application.delete_env(:tymeslot, :calendar_module)
    end)

    for base <- [@source_base, @destination_base] do
      CalendarCircuitBreaker.reset_for_url(:caldav, base)
      CalendarCircuitBreaker.reset_for_url(:radicale, base)
    end

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    source =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: @source_base,
        calendar_paths: ["/cal/"]
      )

    destination =
      insert(:calendar_integration,
        user: user,
        provider: "radicale",
        base_url: @destination_base,
        calendar_paths: ["/dav/team/"],
        calendar_list: [%{"id" => "/dav/team/", "name" => "Team", "selected" => true}]
      )

    # Two occurrences of the series, as the sync caches them: today's, and
    # next week's, shown later today so the week's grid holds both.
    nine_in_berlin =
      today()
      |> DateTime.new!(~T[09:00:00], "Europe/Berlin")
      |> DateTime.shift_zone!("Etc/UTC")

    event = occurrence(source, today(), nine_in_berlin)
    other = occurrence(source, Date.add(today(), 7), at_today(15))

    single =
      insert(:provider_calendar_event,
        calendar_integration: source,
        uid: "lunch",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/lunch.ics",
        summary: "Lunch",
        start_at: at_today(12),
        end_at: at_today(13),
        all_day: false,
        timezone: "Etc/UTC",
        etag: "\"etag-lunch\"",
        raw_ical: single_ical(),
        sync_state: "synced"
      )

    {:ok, conn: conn, destination: destination, event: event, other: other, single: single}
  end

  defp today, do: Date.utc_today()
  defp first_day, do: Date.add(today(), -14)
  defp at_today(hour), do: DateTime.new!(today(), Time.new!(hour, 0, 0), "Etc/UTC")

  describe "while the series is moving" do
    # Made against the series as it was on its old calendar, which the move
    # deletes: neither the moving event's edit nor another's reaches it.
    test "edits of its events are held, then dropped and reported", %{
      conn: conn,
      destination: destination,
      event: event,
      other: other
    } do
      hold_puts()
      expect_delete(204)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      move_series(lv, event, destination)
      assert_receive {:held, :copy, mover}, @task_timeout

      show(lv, other)
      rename(lv, "Daily standup")
      show(lv, event)
      rename(lv, "Monthly standup")
      refute_receive {:held, :edit, _editor}, 200

      release(mover, 201)

      eventually(
        fn ->
          assert render(lv) =~
                   "The series was moved, but 2 changes you made while it was moving were not applied."
        end,
        timeout: @task_timeout
      )

      refute_receive {:held, :edit, _editor}, 200
      assert_series_reloaded(lv, event)
    end

    test "an edit held while it moved is made once the move has failed", %{
      conn: conn,
      destination: destination,
      event: event,
      other: other
    } do
      hold_puts()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      move_series(lv, event, destination)
      assert_receive {:held, :copy, mover}, @task_timeout

      show(lv, other)
      rename(lv, "Daily standup")
      refute_receive {:held, :edit, _editor}, 200

      release(mover, 403)

      assert_receive {:held, :edit, editor}, @task_timeout
      release(editor, 204)
      assert_receive {:put, @series_url, body}, @task_timeout
      assert body =~ "SUMMARY:Daily standup"

      eventually(fn -> assert render(lv) =~ "Could not move the series." end,
        timeout: @task_timeout
      )

      refute render(lv) =~ "were not applied"
    end

    test "is refused while an edit of another of its events is saving", %{
      conn: conn,
      destination: destination,
      event: event,
      other: other
    } do
      hold_puts()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      show(lv, other)
      rename(lv, "Daily standup")
      assert_receive {:held, :edit, editor}, @task_timeout

      move_series(lv, event, destination)

      assert render(lv) =~ "A change to this series is still saving."
      refute_receive {:held, :copy, _mover}, 200

      release(editor, 204)
    end
  end

  describe "while all events are saving" do
    # Made against the occurrence as it was: the series write may have moved
    # its slot, and an override written after it would name a slot the
    # series no longer has.
    test "an edit of another occurrence is held, then dropped and reported", %{
      conn: conn,
      event: event,
      other: other,
      single: single
    } do
      hold_puts()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      write_all(lv, event)
      assert_receive {:held, :edit, writer}, @task_timeout

      show(lv, other)
      rename(lv, "Daily standup")

      # An event outside the series is not held up by it.
      show(lv, single)
      rename(lv, "Long lunch")
      assert_receive {:put, @single_url, lunch}, @task_timeout
      assert lunch =~ "SUMMARY:Long lunch"

      refute_receive {:held, :edit, _second}, 200

      release(writer, 204)

      eventually(
        fn ->
          assert render(lv) =~
                   "The series was updated, but a change you made while it was saving was not applied."
        end,
        timeout: @task_timeout
      )

      # The series' own write only; the held edit never reaches the calendar.
      assert_receive {:put, @series_url, series_body}, @task_timeout
      refute series_body =~ "Daily standup"
      refute_receive {:held, :edit, _second}, 200
      assert_series_reloaded(lv, event)
    end

    test "is refused while an edit of another occurrence is saving", %{
      conn: conn,
      event: event,
      other: other
    } do
      hold_puts()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      show(lv, other)
      rename(lv, "Daily standup")
      assert_receive {:held, :edit, editor}, @task_timeout

      write_all(lv, event)

      assert render(lv) =~
               "A change to this series is still saving. Please make this change once it has saved."

      refute has_element?(lv, "#recurrence-prompt-modal")
      refute_receive {:held, :edit, _series_write}, 200

      release(editor, 204)
      assert_receive {:put, @series_url, body}, @task_timeout
      assert body =~ "SUMMARY:Daily standup"
      refute_receive {:held, :edit, _series_write}, 200
    end
  end

  defp occurrence(integration, date, start_at) do
    key = Calendar.strftime(date, "%Y%m%dT090000")

    insert(:provider_calendar_event,
      calendar_integration: integration,
      uid: "standup@example.com_#{key}",
      provider: "caldav",
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/standup.ics",
      summary: "Weekly standup",
      start_at: start_at,
      end_at: DateTime.add(start_at, 1, :hour),
      all_day: false,
      timezone: "Europe/Berlin",
      recurrence_rule: "FREQ=WEEKLY",
      provider_metadata: %{"uid" => "standup@example.com"},
      etag: "\"etag-1\"",
      raw_ical: series_ical(),
      sync_state: "synced"
    )
  end

  defp series_ical do
    first = Calendar.strftime(first_day(), "%Y%m%d")

    ical([
      "UID:standup@example.com",
      "DTSTART;TZID=Europe/Berlin:#{first}T090000",
      "DTEND;TZID=Europe/Berlin:#{first}T100000",
      "RRULE:FREQ=WEEKLY",
      "SUMMARY:Weekly standup"
    ])
  end

  defp single_ical do
    day = Calendar.strftime(today(), "%Y%m%d")
    ical(["UID:lunch", "DTSTART:#{day}T120000Z", "DTEND:#{day}T130000Z", "SUMMARY:Lunch"])
  end

  defp ical(lines) do
    Enum.join(
      ["BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "DTSTAMP:20260901T090000Z"] ++
        lines ++ ["END:VEVENT", "END:VCALENDAR"],
      "\r\n"
    ) <> "\r\n"
  end

  # Holds every PUT to the series until the test releases it with a status,
  # telling the move's copy (sent with `If-None-Match`) from an edit, and
  # answers a PUT to any other event at once. Every PUT that is answered
  # with a success is recorded.
  defp hold_puts do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
      status =
        if url == @series_url or {"If-None-Match", "*"} in headers do
          kind = if {"If-None-Match", "*"} in headers, do: :copy, else: :edit
          send(test_pid, {:held, kind, self()})
          assert_receive {:release, status}, @task_timeout
          status
        else
          204
        end

      if status < 300, do: send(test_pid, {:put, url, body})
      {:ok, %Req.Response{status: status, body: "", headers: %{}}}
    end)
  end

  defp expect_delete(status) do
    expect(Tymeslot.HTTPClientMock, :delete, fn _url, _headers, _opts ->
      {:ok, %Req.Response{status: status, body: "", headers: %{}}}
    end)
  end

  defp release(pid, status) do
    ref = Process.monitor(pid)
    send(pid, {:release, status})
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @task_timeout
  end

  defp show(lv, event) do
    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})
  end

  defp rename(lv, title) do
    lv
    |> element("#calendar-grid")
    |> render_hook("update_event_title", %{"value" => title})
  end

  defp move_series(lv, event, destination) do
    show(lv, event)

    lv
    |> element("#calendar-grid")
    |> render_hook("update_event_calendar", %{
      "integration-id" => to_string(destination.id),
      "calendar-id" => "/dav/team/"
    })

    lv
    |> element("#confirm-series-move-modal button", "Move series")
    |> render_click()
  end

  # Drops `event` at 14:00 today and applies the move to all events.
  defp write_all(lv, event) do
    lv
    |> element("#calendar-grid")
    |> render_hook("event_dropped", %{
      "event-id" => to_string(event.id),
      "new-date" => Date.to_iso8601(today()),
      "new-hour" => "14",
      "new-minute" => "0",
      "new-end-hour" => "15",
      "new-end-minute" => "0"
    })

    lv
    |> element("#recurrence-prompt-modal [phx-value-scope='all']")
    |> render_click()
  end

  # The series' rows are gone from the source until a sync brings them back,
  # and the grid reloaded rather than keep showing them.
  defp assert_series_reloaded(lv, event) do
    eventually(
      fn -> not has_element?(lv, "[id^='event-#{event.id}-']") end,
      timeout: @task_timeout
    )

    assert ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid) ==
             {:error, :not_found}
  end
end
