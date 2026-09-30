defmodule TymeslotWeb.Dashboard.CalendarGrid.RecurringScopeCalDavLiveViewTest do
  @moduledoc """
  Moving one occurrence of a CalDAV repeating event on the grid and
  choosing, in the recurrence prompt, which occurrences the move applies
  to: this event, this and following, or all events; and a rule change
  whose split a CalDAV series' recurrence rule cannot follow. Google's and
  Outlook's own occurrence choices are covered by the sibling
  `RecurringScopeLiveViewTest`.

  As in the domain's end-to-end tests (`EventEditCalDAVWriteTest`,
  `EventEditCalDAVSplitTest`), the `:calendar_module` seam points back at
  the runtime module, so only the HTTP client is mocked and each choice is
  pinned by the request that tells it apart. Those tests pin the whole of
  each request; this one pins that the prompt's buttons reach them.

  A choice that writes the whole series drops the series' cached rows until
  a sync brings them back, so the grid reloads, and a write waiting behind it
  for the same event is dropped rather than run (see
  `TymeslotWeb.Dashboard.CalendarGrid.EventWrites`).
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  setup :set_mox_global
  setup :verify_on_exit!

  # The provider write runs in a Task; allow for a busy test machine.
  @task_timeout 5_000

  defp swap_env(key, module) do
    previous = Application.get_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tymeslot, key, previous),
        else: Application.delete_env(:tymeslot, key)
    end)
  end

  setup %{conn: conn} do
    swap_env(:calendar_module, Operations)
    swap_env(:google_calendar_api_module, GoogleAPI)
    swap_env(:outlook_calendar_api_module, OutlookAPI)

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    {:ok, conn: conn, user: user}
  end

  # The series started two weeks ago, so today's occurrence is not its first,
  # whose "this and following" would be "all events".
  defp today, do: Date.utc_today()
  defp first_day, do: Date.add(today(), -14)

  describe "an occurrence of a CalDAV series" do
    @series_url "https://caldav.example.com/cal/weekly-standup.ics"

    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://caldav.example.com",
          calendar_paths: ["/cal/"]
        )

      key = Calendar.strftime(today(), "%Y%m%dT090000")

      start_at =
        today()
        |> DateTime.new!(~T[09:00:00], "Europe/Berlin")
        |> DateTime.shift_zone!("Etc/UTC")

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "weekly-standup_#{key}",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/weekly-standup.ics",
          summary: "Weekly standup",
          start_at: start_at,
          end_at: DateTime.add(start_at, 1, :hour),
          all_day: false,
          timezone: "Europe/Berlin",
          recurrence_rule: "FREQ=WEEKLY",
          provider_metadata: %{"uid" => "weekly-standup"},
          etag: "\"etag-1\"",
          raw_ical: caldav_series(),
          sync_state: "synced"
        )

      %{integration: integration, event: event, key: key}
    end

    test "the prompt is offered for it", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      drop(lv, event, 14)

      for scope <- ~w(this_only following all) do
        assert has_element?(lv, "#recurrence-prompt-modal [phx-value-scope='#{scope}']")
      end
    end

    test "this event writes an override of the occurrence into the series", %{
      conn: conn,
      event: event,
      key: key
    } do
      expect_puts(1)
      move_and_choose(conn, event, "this_only")

      assert [{@series_url, body, headers}] = await_puts(1)
      assert {"If-Match", "\"etag-1\""} in headers
      assert "RECURRENCE-ID;TZID=Europe/Berlin:#{key}" in LineFolder.unfold_lines(body)
    end

    test "all events rewrites the series' master", %{conn: conn, event: event} do
      expect_puts(1)
      lv = move_and_choose(conn, event, "all")

      assert [{@series_url, body, _headers}] = await_puts(1)
      lines = LineFolder.unfold_lines(body)
      refute Enum.any?(lines, &String.starts_with?(&1, "RECURRENCE-ID"))
      refute first_start_line() in lines
      assert_series_reloaded(lv, event)
    end

    test "this and following creates the tail beside the series, then ends the series", %{
      conn: conn,
      integration: integration,
      event: event
    } do
      expect_puts(2)
      lv = move_and_choose(conn, event, "following")

      assert [{tail_url, _tail, tail_headers}, {@series_url, _head, head_headers}] =
               await_puts(2)

      assert tail_url != @series_url
      assert {"If-None-Match", "*"} in tail_headers
      assert {"If-Match", "\"etag-1\""} in head_headers
      assert_series_reloaded(lv, event)

      assert_enqueued(
        worker: SyncCalDavCalendarWorker,
        args: %{"calendar_integration_id" => integration.id, "force_full_fetch" => true}
      )
    end

    test "this and following of a count it cannot follow is refused as on Google", %{
      conn: conn,
      event: event
    } do
      # A count over days of the month: the following occurrences' share of
      # it cannot be counted, so no tail is made and nothing is written.
      rule = "FREQ=MONTHLY;BYMONTHDAY=#{first_day().day},#{today().day};COUNT=24"

      event
      |> Changeset.change(
        recurrence_rule: rule,
        raw_ical: String.replace(caldav_series(), "RRULE:FREQ=WEEKLY", "RRULE:" <> rule)
      )
      |> Repo.update!()

      lv = move_and_choose(conn, event, "following")

      eventually(
        fn -> assert render(lv) =~ "repeat rule cannot be split here" end,
        timeout: @task_timeout
      )

      refute render(lv) =~ "Failed to update event - changes reverted"
    end

    test "a change of rule opens the prompt, without this event alone", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("show_event", %{"event-id" => to_string(event.id)})

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_recurrence", %{
        "freq" => "daily",
        "interval" => "1",
        "end_type" => "never"
      })

      assert has_element?(lv, "#recurrence-prompt-modal [phx-value-scope='all']")
      refute has_element?(lv, "#recurrence-prompt-modal [phx-value-scope='this_only']")

      # A CalDAV split keeps every override and exclusion.
      assert has_element?(lv, "#recurrence-prompt-modal [phx-value-scope='following']")
      refute has_element?(lv, "#recurrence-following-notes")
    end

    # Removing the repeat rule of a series member is refused for every scope
    # the prompt could offer (`SeriesEdit.rule_refused?/3` refuses
    # `:following` and `:all` unconditionally), so it is refused here rather
    # than opening a prompt whose every button is a dead end.
    test "choosing does not repeat is refused without a scope prompt", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("show_event", %{"event-id" => to_string(event.id)})

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_recurrence", %{"freq" => "", "end_type" => "never"})

      # The flash is relayed to the parent LiveView, so it lands on the next
      # render rather than in the hook's own reply.
      html = render(lv)

      refute has_element?(lv, "#recurrence-prompt-modal")
      assert html =~ "cannot be removed here"

      assert {:ok, stored} =
               ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid)

      assert stored.recurrence_rule == "FREQ=WEEKLY"
    end

    # A rename made while the series was being moved was made against the
    # occurrence as it was; the move dropped its row, so it is not run.
    test "a change made while the whole series is saving is dropped and reported", %{
      conn: conn,
      event: event
    } do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
        send(test_pid, {:blocked, self()})
        assert_receive :release, @task_timeout
        send(test_pid, {:put, url, body, headers})
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("show_event", %{"event-id" => to_string(event.id)})

      drop(lv, event, 14)
      confirm_scope(lv, "all")

      assert_receive {:blocked, writer}, @task_timeout

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Daily standup"})

      ref = Process.monitor(writer)
      send(writer, :release)
      assert_receive {:DOWN, ^ref, :process, ^writer, _reason}, @task_timeout

      eventually(
        fn ->
          assert render(lv) =~
                   "The series was updated, but a change you made while it was saving was not applied."
        end,
        timeout: @task_timeout
      )

      # One write only, the series'; `verify_on_exit!` fails a second PUT.
      assert [{@series_url, body, _headers}] = await_puts(1)
      refute body =~ "Daily standup"
      assert_series_reloaded(lv, event)
    end
  end

  describe "a rule change the split cannot follow" do
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://caldav.example.com",
          calendar_paths: ["/cal/"]
        )

      key = Calendar.strftime(today(), "%Y%m%dT090000")

      start_at =
        today()
        |> DateTime.new!(~T[09:00:00], "Europe/Berlin")
        |> DateTime.shift_zone!("Etc/UTC")

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "pinned-standup_#{key}",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/pinned-standup.ics",
          summary: "Pinned standup",
          start_at: start_at,
          end_at: DateTime.add(start_at, 1, :hour),
          all_day: false,
          timezone: "Europe/Berlin",
          # A COUNT over an ordinal BYDAY (the second Monday) is outside what
          # `RecurrenceExpander.countable?/1` follows, so a "this and
          # following" split of it is refused (`:unsupported_rule`)
          # before anything is written.
          recurrence_rule: "FREQ=MONTHLY;BYDAY=2MO;COUNT=24",
          provider_metadata: %{"uid" => "pinned-standup"},
          etag: "\"etag-1\"",
          raw_ical: pinned_caldav_series(),
          sync_state: "synced"
        )

      %{event: event}
    end

    # The eager "Changes saved." flash predates the refusal reasons a scoped
    # rule change can now hit, and would otherwise contradict the refusal's
    # own flash once the write answers.
    test "is refused without ever flashing that it saved", %{conn: conn, event: event} do
      lv = change_rule(conn, event)
      confirm_scope(lv, "following")

      eventually(
        fn -> assert render(lv) =~ "cannot be split here" end,
        timeout: @task_timeout
      )

      refute render(lv) =~ "Changes saved."
    end
  end

  defp first_start_line,
    do: "DTSTART;TZID=Europe/Berlin:#{Calendar.strftime(first_day(), "%Y%m%dT090000")}"

  defp caldav_series do
    first = Calendar.strftime(first_day(), "%Y%m%d")

    Enum.join(
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "BEGIN:VEVENT",
        "UID:weekly-standup",
        "DTSTAMP:20260901T090000Z",
        first_start_line(),
        "DTEND;TZID=Europe/Berlin:#{first}T100000",
        "RRULE:FREQ=WEEKLY",
        "SUMMARY:Weekly standup",
        "END:VEVENT",
        "END:VCALENDAR"
      ],
      "\r\n"
    ) <> "\r\n"
  end

  defp pinned_caldav_series do
    first = Calendar.strftime(first_day(), "%Y%m%d")

    Enum.join(
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "BEGIN:VEVENT",
        "UID:pinned-standup",
        "DTSTAMP:20260901T090000Z",
        first_start_line(),
        "DTEND;TZID=Europe/Berlin:#{first}T100000",
        "RRULE:FREQ=MONTHLY;BYDAY=2MO;COUNT=24",
        "SUMMARY:Pinned standup",
        "END:VEVENT",
        "END:VCALENDAR"
      ],
      "\r\n"
    ) <> "\r\n"
  end

  defp expect_puts(count) do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, count, fn url, body, headers, _opts ->
      send(test_pid, {:put, url, body, headers})
      {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
    end)
  end

  defp await_puts(count) do
    for _put <- 1..count do
      assert_receive {:put, url, body, headers}, @task_timeout
      {url, body, headers}
    end
  end

  # Drops `event` on today's grid at `hour` and answers the prompt.
  defp move_and_choose(conn, event, scope) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    drop(lv, event, 14)
    confirm_scope(lv, scope)
    lv
  end

  defp drop(lv, event, hour, date \\ today()) do
    lv
    |> element("#calendar-grid")
    |> render_hook("event_dropped", %{
      "event-id" => to_string(event.id),
      "new-date" => Date.to_iso8601(date),
      "new-hour" => to_string(hour),
      "new-minute" => "0",
      "new-end-hour" => to_string(hour + 1),
      "new-end-minute" => "0"
    })
  end

  # Opens `event` and changes its repeat rule to daily, which asks for a
  # scope.
  defp change_rule(conn, event) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})

    lv
    |> element("#calendar-grid")
    |> render_hook("update_event_recurrence", %{
      "freq" => "daily",
      "interval" => "1",
      "end_type" => "never"
    })

    assert has_element?(lv, "#recurrence-prompt-modal [phx-value-scope='following']")
    lv
  end

  defp confirm_scope(lv, scope) do
    lv
    |> element("#recurrence-prompt-modal [phx-value-scope='#{scope}']")
    |> render_click()
  end

  # The series' rows are gone from the cache until the sync lands, and the
  # grid reloaded rather than keep showing the moved occurrence.
  defp assert_series_reloaded(lv, event) do
    eventually(
      fn -> not has_element?(lv, "[id^='event-#{event.id}-']") end,
      timeout: @task_timeout
    )

    assert ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid) ==
             {:error, :not_found}
  end
end
