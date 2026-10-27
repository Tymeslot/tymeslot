defmodule TymeslotWeb.Dashboard.CalendarGrid.RecurrenceEndUtcSeriesLiveViewTest do
  @moduledoc """
  Ending a series whose start is in UTC on a date, from the recurrence
  editor, by an organiser west of UTC. Every series Tymeslot wrote before
  it wrote them in a zone is such a series, on CalDAV and Outlook alike.

  The editor ends the chosen day in a zone, and the writers read the end
  date back in that same zone. Read in another, 31 December in Los Angeles
  is 1 January in UTC, and the series silently gained an occurrence on the
  1st; a Berlin series on a row reading UTC lost a day the other way.

  Only the HTTP client is mocked: the `:calendar_module` seam and the
  provider API modules point back at the runtime modules.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import TymeslotWeb.RepeatEditorHelpers
  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers, only: [freeze_clock_midweek: 0]

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  # Events are built from "today" and read in the organiser's zone, which is
  # not UTC: near midnight UTC on a Sunday, "today" is last week there.
  setup do: freeze_clock_midweek()

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
    profile = insert(:profile, user: user, timezone: "America/Los_Angeles")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    {:ok, conn: conn, user: user, profile: profile}
  end

  # The series started two weeks ago and repeats weekly at 18:00 UTC, which
  # is the same afternoon in Los Angeles.
  defp today, do: Clock.utc_today()
  defp first_day, do: Date.add(today(), -14)
  defp end_day, do: Date.add(today(), 60)
  defp at_today, do: DateTime.new!(today(), ~T[18:00:00], "Etc/UTC")

  defp utc_row(integration, attrs) do
    insert(
      :provider_calendar_event,
      Map.merge(
        %{
          calendar_integration: integration,
          summary: "Weekly sync",
          start_at: at_today(),
          end_at: DateTime.add(at_today(), 1, :hour),
          all_day: false,
          timezone: "Etc/UTC",
          recurrence_rule: "FREQ=WEEKLY",
          sync_state: "synced"
        },
        attrs
      )
    )
  end

  defp end_series_on(conn, event, date) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})

    lv
    |> element("#calendar-grid")
    |> render_repeat_save(%{
      "freq" => "weekly",
      "interval" => "1",
      "end_type" => "until",
      "until" => Date.to_iso8601(date)
    })

    lv
    |> element("#recurrence-prompt-modal [phx-value-scope='all']")
    |> render_click()
  end

  test "a CalDAV series ends on the chosen day in UTC", %{conn: conn, user: user} do
    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: "https://caldav.example.com",
        calendar_paths: ["/cal/"]
      )

    stamp = Calendar.strftime(today(), "%Y%m%dT180000Z")

    event =
      utc_row(integration, %{
        provider: "caldav",
        uid: "weekly-sync_#{stamp}",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/weekly-sync.ics",
        provider_metadata: %{"uid" => "weekly-sync"},
        etag: "\"etag-1\"",
        raw_ical:
          Enum.join(
            [
              "BEGIN:VCALENDAR",
              "VERSION:2.0",
              "BEGIN:VEVENT",
              "UID:weekly-sync",
              "DTSTAMP:20260901T090000Z",
              "DTSTART:#{Calendar.strftime(first_day(), "%Y%m%d")}T180000Z",
              "DTEND:#{Calendar.strftime(first_day(), "%Y%m%d")}T190000Z",
              "RRULE:FREQ=WEEKLY",
              "SUMMARY:Weekly sync",
              "END:VEVENT",
              "END:VCALENDAR"
            ],
            "\r\n"
          ) <> "\r\n"
      })

    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, fn _url, body, _headers, _opts ->
      send(test_pid, {:put, body})
      {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
    end)

    end_series_on(conn, event, end_day())

    assert_receive {:put, body}, @task_timeout

    assert "RRULE:FREQ=WEEKLY;UNTIL=#{Calendar.strftime(end_day(), "%Y%m%d")}T235959Z" in LineFolder.unfold_lines(
             body
           )
  end

  defp oauth_integration(user, provider, scope) do
    insert(:calendar_integration,
      user: user,
      provider: provider,
      access_token_encrypted: Encryption.encrypt("valid_token"),
      refresh_token_encrypted: Encryption.encrypt("refresh_token"),
      token_expires_at: DateTime.add(Clock.utc_now(), 3600),
      oauth_scope: scope
    )
  end

  # A Google or Outlook row is one occurrence the sync expanded: it names its
  # master and carries no rule.
  # An occurrence as the sync caches it: stamped with its series' rule, read
  # from the master with the master's start, which a rule for the whole
  # series is written against.
  defp provider_occurrence(integration, attrs) do
    {:ok, _rule} =
      SeriesRuleQueries.put(integration.id, "master-1", %{
        rule: "FREQ=WEEKLY",
        master_start: DateTime.new!(first_day(), ~T[18:00:00], "Etc/UTC"),
        fetched_at: DateTime.utc_now()
      })

    utc_row(
      integration,
      Map.merge(
        %{
          provider: integration.provider,
          provider_calendar_id: "team-calendar",
          provider_event_id: "occurrence-1",
          recurring_event_id: "master-1",
          recurrence_rule: "FREQ=WEEKLY"
        },
        attrs
      )
    )
  end

  # Answers every request with `master` and sends back the body of the PATCH.
  defp serve_master(master) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, _url, body, _headers, _opts ->
      if method == :patch, do: send(test_pid, {:patch, Jason.decode!(body)})
      {:ok, %Req.Response{status: 200, body: Jason.encode!(master)}}
    end)
  end

  defp outlook_master(start_wall, zone_label) do
    first = Date.to_iso8601(first_day())
    weekday = today() |> Calendar.strftime("%A") |> String.downcase()

    %{
      "id" => "master-1",
      "type" => "seriesMaster",
      "subject" => "Weekly sync",
      "isAllDay" => false,
      "start" => %{"dateTime" => "#{first}T#{start_wall}.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "#{first}T#{start_wall}.0000000", "timeZone" => "UTC"},
      "originalStartTimeZone" => zone_label,
      "recurrence" => %{
        "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => [weekday]},
        "range" => %{"type" => "noEnd", "startDate" => first}
      }
    }
  end

  defp assert_outlook_end_date(date) do
    assert_receive {:patch, body}, @task_timeout
    assert %{"recurrence" => %{"range" => %{"type" => "endDate", "endDate" => end_date}}} = body
    assert end_date == Date.to_iso8601(date)
  end

  test "a Google series ends on the chosen day in UTC", %{conn: conn, user: user} do
    integration = oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar")
    event = provider_occurrence(integration, %{uid: "weekly_today"})
    first = Date.to_iso8601(first_day())

    serve_master(%{
      "id" => "master-1",
      "iCalUID" => "weekly@google.com",
      "summary" => "Weekly sync",
      "start" => %{"dateTime" => "#{first}T18:00:00Z", "timeZone" => "Etc/UTC"},
      "end" => %{"dateTime" => "#{first}T19:00:00Z", "timeZone" => "Etc/UTC"},
      "recurrence" => ["RRULE:FREQ=WEEKLY"]
    })

    end_series_on(conn, event, end_day())

    assert_receive {:patch, body}, @task_timeout

    assert body["recurrence"] == [
             "RRULE:FREQ=WEEKLY;UNTIL=#{Calendar.strftime(end_day(), "%Y%m%d")}T235959Z"
           ]
  end

  test "an Outlook series ends on the chosen day", %{conn: conn, user: user} do
    integration =
      oauth_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

    event = provider_occurrence(integration, %{uid: "weekly-occurrence-today"})
    serve_master(outlook_master("18:00:00", "UTC"))

    end_series_on(conn, event, end_day())

    assert_outlook_end_date(end_day())
  end

  # A row refreshed by a change notification reads UTC whatever the series'
  # zone, while the master Graph returns names Berlin: the end date is read
  # in the zone the editor ended the day in, not the master's.
  test "an Outlook series whose row reads UTC ends on the chosen day in Berlin", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    profile |> Changeset.change(timezone: "Europe/Berlin") |> Repo.update!()

    integration =
      oauth_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

    event = provider_occurrence(integration, %{uid: "weekly-occurrence-today"})
    serve_master(outlook_master("18:00:00", "W. Europe Standard Time"))

    end_series_on(conn, event, end_day())

    assert_outlook_end_date(end_day())
  end
end
