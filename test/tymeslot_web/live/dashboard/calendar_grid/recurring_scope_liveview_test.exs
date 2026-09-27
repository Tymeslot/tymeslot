defmodule TymeslotWeb.Dashboard.CalendarGrid.RecurringScopeLiveViewTest do
  @moduledoc """
  Moving one occurrence of a repeating event on the grid and choosing, in
  the recurrence prompt, which occurrences the move applies to: this event,
  this and following, or all events, on Google, Outlook and CalDAV.

  As in the domain's end-to-end tests (`EventEditProviderSeriesTest`,
  `EventEditProviderSplitTest`, `EventEditCalDAVWriteTest`,
  `EventEditCalDAVSplitTest`), the `:calendar_module` seam and the provider
  API modules point back at the runtime modules, so only the HTTP client is
  mocked and each choice is pinned by the request that tells it apart. Those
  modules pin the whole of each request; this one pins that the prompt's
  buttons reach them.

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

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

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
  defp at_today(hour), do: DateTime.new!(today(), Time.new!(hour, 0, 0), "Etc/UTC")

  describe "an occurrence of a Google series" do
    @google_events "https://www.googleapis.com/calendar/v3/calendars/team-calendar/events"
    @google_master_url @google_events <> "/series1"

    setup %{user: user} do
      integration =
        oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar")

      stamp = Calendar.strftime(today(), "%Y%m%dT090000Z")

      event =
        oauth_occurrence(integration, %{
          provider: "google",
          uid: "weekly_#{stamp}",
          provider_event_id: "series1_#{stamp}",
          recurring_event_id: "series1"
        })

      serve(google_master())
      %{integration: integration, event: event}
    end

    test "this event is written to the occurrence's own id", %{conn: conn, event: event} do
      move_and_choose(conn, event, "this_only")

      assert [{:put, url, _body}] = await_requests(1)
      assert url =~ @google_events <> "/" <> event.provider_event_id
    end

    test "all events patches the master", %{conn: conn, event: event} do
      lv = move_and_choose(conn, event, "all")

      assert [{:get, @google_master_url, _read}, {:patch, url, _body}] = await_requests(2)
      assert url == @google_master_url <> "?sendUpdates=none"
      assert_series_reloaded(lv, event)
    end

    test "this and following creates the new series, then ends the master", %{
      conn: conn,
      integration: integration,
      event: event
    } do
      lv = move_and_choose(conn, event, "following")

      # The master, then its occurrences changed on their own, to carry.
      assert [
               {:get, _master_url, _read},
               {:get, list_url, _list},
               {:post, post_url, _tail},
               {:patch, patch_url, _head}
             ] = await_requests(4)

      assert list_url =~ "iCalUID=series1%40google.com"

      assert String.starts_with?(post_url, @google_events <> "?")
      assert patch_url == @google_master_url <> "?sendUpdates=none"
      assert_series_reloaded(lv, event)

      assert_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "a move the series' rule cannot follow is refused with its reason", %{
      conn: conn,
      event: event
    } do
      serve(%{google_master() | "recurrence" => ["RRULE:FREQ=MONTHLY;BYDAY=1MO"]})

      # To the next day, which the first Monday of the month cannot follow.
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      drop(lv, event, 14, Date.add(today(), 1))
      confirm_scope(lv, "all")

      assert [{:get, @google_master_url, _read}] = await_requests(1)

      eventually(
        fn -> assert render(lv) =~ "This series repeats on fixed days" end,
        timeout: @task_timeout
      )

      refute render(lv) =~ "Failed to update event - changes reverted"
    end

    test "a change of rule warns under this and following what it cannot carry", %{
      conn: conn,
      event: event
    } do
      lv = change_rule(conn, event)

      assert lv |> element("#recurrence-following-notes") |> render() =~
               "Later events that were changed or cancelled on their own keep that only on dates the new pattern still includes."
    end

    test "a move carries every changed occurrence, so its prompt has no warning", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      drop(lv, event, 14)

      assert has_element?(lv, "#recurrence-prompt-modal [phx-value-scope='following']")
      refute has_element?(lv, "#recurrence-following-notes")
    end
  end

  describe "an occurrence of an Outlook series" do
    @outlook_master_url "https://graph.microsoft.com/v1.0/me/events/master-1"

    setup %{user: user} do
      integration =
        oauth_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

      event =
        oauth_occurrence(integration, %{
          provider: "outlook",
          uid: "weekly-occurrence-today",
          provider_event_id: "occurrence-1",
          recurring_event_id: "master-1",
          provider_metadata: %{"type" => "occurrence"}
        })

      serve(outlook_master())
      %{event: event}
    end

    test "this event is patched on the occurrence's own id", %{conn: conn, event: event} do
      move_and_choose(conn, event, "this_only")

      assert [{:patch, url, _body}] = await_requests(1)
      assert url =~ "occurrence-1"
    end

    test "all events patches the master", %{conn: conn, event: event} do
      lv = move_and_choose(conn, event, "all")

      assert [{:get, @outlook_master_url, _read}, {:patch, @outlook_master_url, _body}] =
               await_requests(2)

      assert_series_reloaded(lv, event)
    end

    test "this and following creates the new series, then ends the master", %{
      conn: conn,
      event: event
    } do
      lv = move_and_choose(conn, event, "following")

      # The master, the calendar it sits in, where the new series goes, and
      # its occurrences changed on their own, to carry.
      assert [
               {:get, _master_url, _read},
               {:get, _calendar_url, _calendar},
               {:get, exceptions_url, _exceptions},
               {:post, _post_url, _tail},
               {:patch, url, body}
             ] =
               await_requests(5)

      assert exceptions_url =~ "exceptionOccurrences"
      assert url == @outlook_master_url

      assert %{"recurrence" => %{"range" => %{"type" => "endDate"}}} = Jason.decode!(body)
      assert_series_reloaded(lv, event)
    end

    test "a change of rule warns under this and following", %{conn: conn, event: event} do
      lv = change_rule(conn, event)
      assert has_element?(lv, "#recurrence-following-notes")
    end
  end

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

  defp oauth_integration(user, provider, scope) do
    insert(:calendar_integration,
      user: user,
      provider: provider,
      access_token_encrypted: Encryption.encrypt("valid_token"),
      refresh_token_encrypted: Encryption.encrypt("refresh_token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
      oauth_scope: scope
    )
  end

  defp oauth_occurrence(integration, attrs) do
    insert(
      :provider_calendar_event,
      Map.merge(
        %{
          calendar_integration: integration,
          provider_calendar_id: "team-calendar",
          summary: "Weekly sync",
          start_at: at_today(9),
          end_at: at_today(10),
          all_day: false,
          timezone: "Etc/UTC",
          sync_state: "synced"
        },
        attrs
      )
    )
  end

  defp google_master do
    first = Date.to_iso8601(first_day())

    %{
      "id" => "series1",
      "iCalUID" => "series1@google.com",
      "summary" => "Weekly sync",
      "start" => %{"dateTime" => "#{first}T09:00:00Z", "timeZone" => "Etc/UTC"},
      "end" => %{"dateTime" => "#{first}T10:00:00Z", "timeZone" => "Etc/UTC"},
      "recurrence" => ["RRULE:FREQ=WEEKLY"]
    }
  end

  defp outlook_master do
    first = Date.to_iso8601(first_day())
    weekday = today() |> Calendar.strftime("%A") |> String.downcase()

    %{
      "id" => "master-1",
      "type" => "seriesMaster",
      "subject" => "Weekly sync",
      "isAllDay" => false,
      "start" => %{"dateTime" => "#{first}T09:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "#{first}T10:00:00.0000000", "timeZone" => "UTC"},
      "originalStartTimeZone" => "UTC",
      "recurrence" => %{
        "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => [weekday]},
        "range" => %{"type" => "noEnd", "startDate" => first}
      }
    }
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

  # Answers every Google or Outlook request with the series' master, or a
  # new series for a create, and records it, in order.
  defp serve(master) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:request, method, url, body})

      case method do
        :post -> {:ok, %Req.Response{status: 200, body: Jason.encode!(new_series())}}
        :delete -> {:ok, %Req.Response{status: 204, body: ""}}
        _read_or_write -> {:ok, %Req.Response{status: 200, body: Jason.encode!(master)}}
      end
    end)
  end

  defp new_series, do: %{"id" => "tail1", "iCalUID" => "tail1@example.com"}

  defp await_requests(count) do
    for _request <- 1..count do
      assert_receive {:request, method, url, body}, @task_timeout
      {method, url, body}
    end
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
