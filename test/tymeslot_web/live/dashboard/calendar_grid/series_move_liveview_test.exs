defmodule TymeslotWeb.Dashboard.CalendarGrid.SeriesMoveLiveViewTest do
  @moduledoc """
  Choosing another calendar for an event of a recurring series in the
  detail modal, end to end: the confirmation, what it says the move will
  not carry, and what the grid shows once the provider has answered, on
  Google, Outlook and the CalDAV family.

  As in the domain's end-to-end tests (`SeriesTransferCalDAVTest`,
  `SeriesTransferGoogleTest`, `SeriesTransferOutlookTest`), only the HTTP
  client is mocked, and each family's move is pinned by the request that
  tells it apart: a CalDAV `PUT` with `If-None-Match` to the destination
  then a `DELETE` at the source, Google's own `/move`, and an Outlook
  create in the destination calendar then a delete of the master. Those
  modules pin the whole of each request; this one pins that confirming the
  modal reaches them, and that cancelling it reaches nothing.
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
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption

  setup :set_mox_global
  setup :verify_on_exit!

  # The provider writes run in a Task; allow for a busy test machine.
  @task_timeout 5_000

  @source_base "https://source.example.org"
  @destination_base "https://dest.example.net"
  @series_href "/cal/standup.ics"

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
    # An edit of the series reaches the HTTP client too (see the tests of a
    # change made while the series is moving).
    swap_env(:calendar_module, Operations)
    swap_env(:google_calendar_api_module, GoogleAPI)
    swap_env(:outlook_calendar_api_module, OutlookAPI)

    for base <- [@source_base, @destination_base] do
      CalendarCircuitBreaker.reset_for_url(:caldav, base)
      CalendarCircuitBreaker.reset_for_url(:radicale, base)
    end

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    {:ok, conn: conn, user: user}
  end

  defp today, do: Date.utc_today()
  defp first_day, do: Date.add(today(), -14)
  defp at_today(hour), do: DateTime.new!(today(), Time.new!(hour, 0, 0), "Etc/UTC")

  describe "an event of a CalDAV series" do
    setup %{user: user} do
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

      # Today's occurrence, as the sync caches it: under the series' UID and
      # the occurrence's key.
      key = Calendar.strftime(today(), "%Y%m%dT090000")

      start_at =
        today()
        |> DateTime.new!(~T[09:00:00], "Europe/Berlin")
        |> DateTime.shift_zone!("Etc/UTC")

      event =
        insert(:provider_calendar_event,
          calendar_integration: source,
          uid: "standup@example.com_#{key}",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: @series_href,
          summary: "Weekly standup",
          start_at: start_at,
          end_at: DateTime.add(start_at, 1, :hour),
          all_day: false,
          timezone: "Europe/Berlin",
          recurrence_rule: "FREQ=WEEKLY",
          provider_metadata: %{"uid" => "standup@example.com"},
          etag: "\"etag-1\"",
          raw_ical: caldav_series(),
          sync_state: "synced"
        )

      %{source: source, destination: destination, event: event}
    end

    test "confirming copies the series to the destination, then deletes the original", %{
      conn: conn,
      destination: destination,
      event: event
    } do
      expect_put(201)
      expect_delete(204)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      choose_calendar(lv, event, destination, "/dav/team/")

      assert render(lv) =~ "Move every event in this series to Team?"
      refute has_element?(lv, "#series-move-notes")

      confirm(lv)

      assert_receive {:http, :put, put_url, _copy, put_headers}, @task_timeout
      assert_receive {:http, :delete, delete_url, nil, delete_headers}, @task_timeout

      assert String.starts_with?(put_url, @destination_base <> "/dav/team/")
      assert {"If-None-Match", "*"} in put_headers
      assert delete_url == @source_base <> @series_href
      assert {"If-Match", "\"etag-1\""} in delete_headers

      eventually(fn -> assert render(lv) =~ "The series was moved to Team." end,
        timeout: @task_timeout
      )

      assert_series_reloaded(lv, event)
    end

    test "an original the source will not delete is reported as left behind", %{
      conn: conn,
      destination: destination,
      event: event
    } do
      expect_put(201)
      expect_delete(412)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      choose_calendar(lv, event, destination, "/dav/team/")
      confirm(lv)

      eventually(
        fn ->
          assert render(lv) =~
                   "The series was copied to Team, but the original series could not be removed."
        end,
        timeout: @task_timeout
      )

      refute render(lv) =~ "The series was moved to Team."
    end

    test "cancelling writes nothing and leaves the event where it was", %{
      conn: conn,
      source: source,
      destination: destination,
      event: event
    } do
      test_pid = self()

      for {function, arity_fun} <- [
            put: fn url, _body, _headers, _opts -> send(test_pid, {:unexpected, url}) end,
            delete: fn url, _headers, _opts -> send(test_pid, {:unexpected, url}) end,
            request: fn _method, url, _body, _headers, _opts ->
              send(test_pid, {:unexpected, url})
            end
          ] do
        stub(Tymeslot.HTTPClientMock, function, arity_fun)
      end

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      choose_calendar(lv, event, destination, "/dav/team/")
      assert has_element?(lv, "#confirm-series-move-modal")

      lv
      |> element("#confirm-series-move-modal button", "Cancel")
      |> render_click()

      refute has_element?(lv, "#confirm-series-move-modal")
      refute_receive {:unexpected, _url}, 200

      assert has_element?(lv, "[id^='event-#{event.id}-']")
      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
      assert row.calendar_integration_id == source.id
    end

    test "a series with a change still saving is not moved until it has saved", %{
      conn: conn,
      destination: destination,
      event: event
    } do
      block_puts()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      choose_calendar(lv, event, destination, "/dav/team/")
      rename(lv, "Daily standup")
      assert_receive {:put_blocked, :edit, editor}, @task_timeout

      confirm(lv)

      assert render(lv) =~ "A change to this series is still saving."
      refute_receive {:put_blocked, :copy, _mover}, 200

      release(editor)
    end

    # A rename made while the series was moving was made against the series
    # as it was on its old calendar, which the move has deleted, so the one
    # still waiting to be written is not run.
    test "a change made while the series is moving is dropped and reported", %{
      conn: conn,
      destination: destination,
      event: event
    } do
      block_puts()
      expect_delete(204)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      choose_calendar(lv, event, destination, "/dav/team/")
      confirm(lv)
      assert_receive {:put_blocked, :copy, mover}, @task_timeout

      lv
      |> element("#calendar-grid")
      |> render_hook("show_event", %{"event-id" => to_string(event.id)})

      rename(lv, "Daily standup")
      assert_receive {:put_blocked, :edit, editor}, @task_timeout
      rename(lv, "Monthly standup")

      release(mover)

      eventually(
        fn ->
          assert render(lv) =~
                   "The series was moved, but a change you made while it was moving was not applied."
        end,
        timeout: @task_timeout
      )

      release(editor)

      # The waiting rename never reaches the calendar.
      refute_receive {:put_blocked, :edit, _second}, 200
      assert_series_reloaded(lv, event)
    end

    test "a calendar of another kind of account is refused without asking", %{
      conn: conn,
      user: user,
      event: event
    } do
      google = oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      choose_calendar(lv, event, google, "primary")

      refute has_element?(lv, "#confirm-series-move-modal")

      assert render(lv) =~
               "A recurring event can only be moved to a calendar of the same kind of account"
    end
  end

  describe "an event of a Google series" do
    @google_api "https://www.googleapis.com/calendar/v3"

    setup %{user: user} do
      source =
        oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar",
          calendar_list: [
            %{"id" => "team-calendar", "name" => "Team", "selected" => true},
            %{"id" => "projects", "name" => "Projects", "selected" => true}
          ]
        )

      stamp = Calendar.strftime(today(), "%Y%m%dT090000Z")

      event =
        oauth_occurrence(source, %{
          provider: "google",
          uid: "series1@google.com_#{stamp}",
          provider_event_id: "series1_#{stamp}",
          recurring_event_id: "series1"
        })

      %{source: source, event: event}
    end

    test "within one account, confirming moves the series with Google's own move", %{
      conn: conn,
      source: source,
      event: event
    } do
      serve(google_master(), google_master())

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      choose_calendar(lv, event, source, "projects")

      assert render(lv) =~ "Move every event in this series to Projects?"
      refute has_element?(lv, "#series-move-notes")

      confirm(lv)

      assert_receive {:request, :post, url, _body}, @task_timeout
      assert url =~ @google_api <> "/calendars/team-calendar/events/series1/move?"
      assert url =~ "destination=projects"
      refute_receive {:request, _method, _url, _body}, 100

      eventually(fn -> assert render(lv) =~ "The series was moved to Projects." end,
        timeout: @task_timeout
      )

      assert_series_reloaded(lv, event)
    end

    test "to another account, the confirmation says edited events are reset", %{
      conn: conn,
      user: user,
      event: event
    } do
      other = oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      choose_calendar(lv, event, other, "primary")

      assert has_element?(
               lv,
               "#series-move-notes li",
               "changed on their own go back to the series' usual pattern"
             )

      refute render(lv) =~ "Teams"
    end
  end

  describe "an event of an Outlook series" do
    @graph "https://graph.microsoft.com/v1.0"

    setup %{user: user} do
      source =
        oauth_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

      destination =
        oauth_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite",
          calendar_list: [
            %{"id" => "projects-calendar", "name" => "Projects", "selected" => true}
          ]
        )

      event =
        oauth_occurrence(source, %{
          provider: "outlook",
          provider_calendar_id: "primary",
          uid: "weekly-occurrence-today",
          provider_event_id: "occurrence-1",
          recurring_event_id: "master-1",
          provider_metadata: %{"type" => "occurrence"},
          attendees: [%{"email" => "guest@example.com", "name" => "Guest"}]
        })

      %{destination: destination, event: event}
    end

    test "the confirmation says what the copy does not carry", %{
      conn: conn,
      destination: destination,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      choose_calendar(lv, event, destination, "projects-calendar")

      assert render(lv) =~ "Move every event in this series to Projects?"
      assert has_element?(lv, "#series-move-notes li", "Teams meeting")
      assert has_element?(lv, "#series-move-notes li", "Guests are sent a cancellation")
      assert has_element?(lv, "#series-move-notes li", "changed or cancelled on their own")
    end

    test "confirming creates the series in the destination calendar, then deletes the master",
         %{conn: conn, destination: destination, event: event} do
      serve(outlook_master(), %{"id" => "copy-1", "iCalUId" => "copy-1-uid"})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      choose_calendar(lv, event, destination, "projects-calendar")
      confirm(lv)

      assert_receive {:request, :get, _master_url, _read}, @task_timeout
      assert_receive {:request, :post, post_url, _body}, @task_timeout
      assert_receive {:request, :delete, delete_url, _none}, @task_timeout

      assert post_url =~ @graph <> "/me/calendars/projects-calendar/events"
      assert delete_url =~ @graph <> "/me/events/master-1"

      eventually(fn -> assert render(lv) =~ "The series was moved to Projects." end,
        timeout: @task_timeout
      )

      assert_series_reloaded(lv, event)
    end
  end

  defp oauth_integration(user, provider, scope, attrs \\ []) do
    insert(
      :calendar_integration,
      [
        user: user,
        provider: provider,
        access_token_encrypted: Encryption.encrypt("valid_token"),
        refresh_token_encrypted: Encryption.encrypt("refresh_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        oauth_scope: scope
      ] ++ attrs
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
      "iCalUId" => "master-1-uid",
      "type" => "seriesMaster",
      "subject" => "Weekly sync",
      "isAllDay" => false,
      "start" => %{"dateTime" => "#{first}T09:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "#{first}T10:00:00.0000000", "timeZone" => "UTC"},
      "originalStartTimeZone" => "UTC",
      "originalEndTimeZone" => "UTC",
      "recurrence" => %{
        "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => [weekday]},
        "range" => %{"type" => "noEnd", "startDate" => first}
      }
    }
  end

  defp caldav_series do
    first = Calendar.strftime(first_day(), "%Y%m%d")

    Enum.join(
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "BEGIN:VEVENT",
        "UID:standup@example.com",
        "DTSTAMP:20260901T090000Z",
        "DTSTART;TZID=Europe/Berlin:#{first}T090000",
        "DTEND;TZID=Europe/Berlin:#{first}T100000",
        "RRULE:FREQ=WEEKLY",
        "SUMMARY:Weekly standup",
        "END:VEVENT",
        "END:VCALENDAR"
      ],
      "\r\n"
    ) <> "\r\n"
  end

  # Answers every Google or Outlook request, and records it, in order: a
  # read with the series' master, a `POST` with `posted` (the master Google's
  # move answers with, or the copy Graph creates), and a delete with nothing.
  defp serve(master, posted) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:request, method, url, body})

      case method do
        :get -> {:ok, %Req.Response{status: 200, body: Jason.encode!(master)}}
        :post -> {:ok, %Req.Response{status: 201, body: Jason.encode!(posted)}}
        :delete -> {:ok, %Req.Response{status: 204, body: ""}}
      end
    end)
  end

  defp expect_put(status) do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
      send(test_pid, {:http, :put, url, body, headers})
      {:ok, %Req.Response{status: status, body: "", headers: %{}}}
    end)
  end

  defp expect_delete(status) do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :delete, fn url, headers, _opts ->
      send(test_pid, {:http, :delete, url, nil, headers})
      {:ok, %Req.Response{status: status, body: "", headers: %{}}}
    end)
  end

  # Holds every CalDAV PUT until the test releases it: the move's copy (sent
  # with `If-None-Match`) and an edit of the series alike.
  defp block_puts do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :put, fn _url, _body, headers, _opts ->
      kind = if {"If-None-Match", "*"} in headers, do: :copy, else: :edit
      send(test_pid, {:put_blocked, kind, self()})

      receive do
        :release -> {:ok, %Req.Response{status: 201, body: "", headers: %{}}}
      after
        @task_timeout -> {:error, :timeout}
      end
    end)
  end

  defp release(pid) do
    ref = Process.monitor(pid)
    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @task_timeout
  end

  defp rename(lv, title) do
    lv
    |> element("#calendar-grid")
    |> render_hook("update_event_title", %{"value" => title})
  end

  defp choose_calendar(lv, event, integration, calendar_id) do
    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})

    lv
    |> element("#calendar-grid")
    |> render_hook("update_event_calendar", %{
      "integration-id" => to_string(integration.id),
      "calendar-id" => calendar_id
    })
  end

  defp confirm(lv) do
    lv
    |> element("#confirm-series-move-modal button", "Move series")
    |> render_click()
  end

  # The series' rows are gone from the source until the destination's sync
  # brings them back, and the grid reloaded rather than keep showing them.
  defp assert_series_reloaded(lv, event) do
    eventually(
      fn -> not has_element?(lv, "[id^='event-#{event.id}-']") end,
      timeout: @task_timeout
    )

    assert ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid) ==
             {:error, :not_found}
  end
end
