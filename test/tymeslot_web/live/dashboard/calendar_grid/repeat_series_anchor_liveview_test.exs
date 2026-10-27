defmodule TymeslotWeb.Dashboard.CalendarGrid.RepeatSeriesAnchorLiveViewTest do
  @moduledoc """
  A weekly series that began on Wednesday 30 September, opened on its
  14 October occurrence and switched to monthly "on the start's day", end to
  end on Google, Outlook and CalDAV.

  The editor builds the pattern from the series' first start, which is what
  a rule written to all of it is read from: "on day 30". Saving asks for a
  scope, and the prompt shows what each one writes: all events "on day 30",
  this and following, a new series from 14 October, "on day 14". The tests
  check the provider receives exactly that, and that Outlook, which cannot
  skip the months without a 30th, has its "All events" refused in the
  prompt rather than written.

  The grid is moved to 14 October so the dates are the same on any day the
  suite runs. As in `RepeatPatternsLiveViewTest`, only the HTTP client is
  mocked.
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
  import TymeslotWeb.RepeatSeriesFixtures

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.Runtime.Operations

  setup :set_mox_global
  setup :verify_on_exit!

  @all_summary "Repeats monthly on day 30"
  @following_summary "Repeats monthly on day 14"

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

  describe "a Google series" do
    setup %{user: user} do
      integration = oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar")
      cache_series_rule(integration, "series1")

      event =
        occurrence(integration, %{
          provider: "google",
          uid: "weekly_20261014T090000Z",
          provider_event_id: "series1_20261014T090000Z",
          recurring_event_id: "series1"
        })

      serve(google_master())

      %{event: event}
    end

    test "all events repeats on the series' day, as the prompt says", %{conn: conn, event: event} do
      lv = stage_monthly_and_save(conn, event)
      confirm_scope(lv, "all")

      assert [{:get, _master, _read}, {:patch, _url, body}] = await_requests(2)
      # The master still starts on 30 September, so the 30th.
      assert Jason.decode!(body)["recurrence"] == ["RRULE:FREQ=MONTHLY"]
    end

    test "this and following starts a series on the 14th, as the prompt says", %{
      conn: conn,
      event: event
    } do
      lv = stage_monthly_and_save(conn, event)
      confirm_scope(lv, "following")

      assert [_master, _list, {:post, _url, tail}, {:patch, _head_url, _head}] =
               await_requests(4)

      tail = Jason.decode!(tail)
      assert tail["recurrence"] == ["RRULE:FREQ=MONTHLY"]
      assert tail["start"]["dateTime"] =~ "2026-10-14T09:00:00"
    end
  end

  describe "an Outlook series" do
    setup %{user: user} do
      integration =
        oauth_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

      cache_series_rule(integration, "master-1")

      event =
        occurrence(integration, %{
          provider: "outlook",
          uid: "weekly-occurrence-20261014",
          provider_event_id: "occurrence-1",
          recurring_event_id: "master-1",
          provider_metadata: %{"type" => "occurrence"}
        })

      serve(outlook_master())

      %{event: event}
    end

    # Graph would move the 30th to 28 February rather than skip February.
    test "all events is refused in the prompt, with the reason, and not offered", %{
      conn: conn,
      event: event
    } do
      lv = stage_monthly_and_save(conn, event)

      assert has_element?(
               lv,
               "#recurrence-scope-all [data-role='scope-refusal']",
               "Outlook can't skip the months"
             )

      refute has_element?(lv, "#recurrence-prompt-modal [phx-value-scope='all']")
      refute_receive {:request, _method, _url, _body}, 200
    end

    test "this and following starts a series on the 14th, as the prompt says", %{
      conn: conn,
      event: event
    } do
      lv = stage_monthly_and_save(conn, event)
      confirm_scope(lv, "following")

      requests = await_requests(5)
      assert {:post, _url, tail} = Enum.find(requests, &match?({:post, _url, _body}, &1))

      assert %{
               "pattern" => %{"type" => "absoluteMonthly", "dayOfMonth" => 14},
               "range" => %{"startDate" => "2026-10-14"}
             } = Jason.decode!(tail)["recurrence"]
    end

    test "all events of a yearly pattern is written on the series' date", %{
      conn: conn,
      event: event
    } do
      lv = open(conn, event)
      pick(lv, %{"freq" => "yearly"})

      assert render(lv) =~ "Repeats yearly on 30 September"

      save(lv)
      assert has_element?(lv, "#recurrence-scope-following", "Repeats yearly on 14 October")
      confirm_scope(lv, "all")

      assert [{:get, _master, _read}, {:patch, _url, body}] = await_requests(2)

      assert %{"type" => "absoluteYearly", "dayOfMonth" => 30, "month" => 9} =
               Jason.decode!(body)["recurrence"]["pattern"]
    end
  end

  describe "a CalDAV series" do
    @series_url "https://caldav.example.com/cal/weekly-standup.ics"

    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://caldav.example.com",
          calendar_paths: ["/cal/"]
        )

      event =
        occurrence(integration, %{
          provider: "caldav",
          provider_calendar_id: "/cal/",
          uid: "weekly-standup_20261014T090000",
          provider_event_id: "/cal/weekly-standup.ics",
          provider_metadata: %{"uid" => "weekly-standup"},
          etag: "\"etag-1\"",
          raw_ical: caldav_series()
        })

      %{event: event}
    end

    test "all events rewrites the master's rule, read from its 30 September start", %{
      conn: conn,
      event: event
    } do
      expect_puts(1)
      lv = stage_monthly_and_save(conn, event)
      confirm_scope(lv, "all")

      assert [{@series_url, body}] = await_puts(1)
      lines = LineFolder.unfold_lines(body)
      assert "DTSTART:20260930T090000Z" in lines
      assert "RRULE:FREQ=MONTHLY" in lines
    end

    test "this and following starts a series on the 14th, as the prompt says", %{
      conn: conn,
      event: event
    } do
      expect_puts(2)
      lv = stage_monthly_and_save(conn, event)
      confirm_scope(lv, "following")

      [{tail_url, tail}, {@series_url, _head}] = await_puts(2)
      assert tail_url != @series_url

      lines = LineFolder.unfold_lines(tail)
      assert Enum.any?(lines, &(&1 =~ ~r/^DTSTART.*20261014T0900/))
      assert "RRULE:FREQ=MONTHLY" in lines
    end
  end

  # The 14 October occurrence, moved on its own to Thursday 15 October. A
  # change of it and the following ones splits the series where the series
  # put it, the 14th, so that is what its pattern is built from.
  describe "an occurrence moved on its own" do
    test "of a Google series starts the following ones on its original day", %{
      conn: conn,
      user: user
    } do
      integration = oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar")
      cache_series_rule(integration, "series1")

      event =
        occurrence(integration, %{
          provider: "google",
          uid: "weekly_20261014T090000Z",
          provider_event_id: "series1_20261014T090000Z",
          recurring_event_id: "series1",
          start_at: ~U[2026-10-15 09:00:00Z],
          end_at: ~U[2026-10-15 10:00:00Z]
        })

      serve(google_master())
      lv = open(conn, event, "2026-10-15")
      pick(lv, %{"freq" => "monthly"})
      save(lv)

      assert prompt_summary(lv, :following) =~ @following_summary
      confirm_scope(lv, "following")

      assert [_master, _list, {:post, _url, tail}, {:patch, _head_url, _head}] =
               await_requests(4)

      assert Jason.decode!(tail)["recurrence"] == ["RRULE:FREQ=MONTHLY"]
    end

    # Moved from Wednesday 28 October to the 29th: Outlook takes a monthly
    # series on the 28th, and would refuse one on the 29th.
    test "of an Outlook series is checked against its original day", %{
      conn: conn,
      user: user
    } do
      integration =
        oauth_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

      cache_series_rule(integration, "master-1")

      event =
        occurrence(integration, %{
          provider: "outlook",
          uid: "weekly-occurrence-20261028",
          provider_event_id: "occurrence-28",
          recurring_event_id: "master-1",
          provider_metadata: %{"type" => "exception", "originalStart" => "2026-10-28T09:00:00Z"},
          start_at: ~U[2026-10-29 09:00:00Z],
          end_at: ~U[2026-10-29 10:00:00Z]
        })

      serve(outlook_master())
      lv = open(conn, event, "2026-10-29")
      pick(lv, %{"freq" => "monthly"})
      save(lv)

      assert prompt_summary(lv, :following) =~ "Repeats monthly on day 28"
      refute has_element?(lv, "#recurrence-scope-following [data-role='scope-refusal']")
      confirm_scope(lv, "following")

      requests = await_requests(5)
      assert {:post, _url, tail} = Enum.find(requests, &match?({:post, _url, _body}, &1))

      assert %{
               "pattern" => %{"type" => "absoluteMonthly", "dayOfMonth" => 28},
               "range" => %{"startDate" => "2026-10-28"}
             } = Jason.decode!(tail)["recurrence"]
    end

    test "of a CalDAV series starts the following ones on its original day", %{
      conn: conn,
      user: user
    } do
      override = [
        "BEGIN:VEVENT",
        "UID:weekly-standup",
        "RECURRENCE-ID:20261014T090000Z",
        "DTSTART:20261015T090000Z",
        "DTEND:20261015T100000Z",
        "SUMMARY:Weekly standup",
        "END:VEVENT"
      ]

      event =
        user
        |> caldav_integration()
        |> caldav_occurrence(%{
          start_at: ~U[2026-10-15 09:00:00Z],
          end_at: ~U[2026-10-15 10:00:00Z],
          raw_ical: caldav_series("FREQ=WEEKLY;BYDAY=WE", override)
        })

      lv = open(conn, event, "2026-10-15")
      pick(lv, %{"freq" => "monthly"})

      expect_puts(2)
      save(lv)
      assert prompt_summary(lv, :following) =~ @following_summary
      confirm_scope(lv, "following")

      [{tail_url, tail}, {@series_url, _head}] = await_puts(2)
      assert tail_url != @series_url

      lines = LineFolder.unfold_lines(tail)
      assert Enum.any?(lines, &(&1 =~ ~r/^DTSTART.*20261014T0900/))
      assert "RRULE:FREQ=MONTHLY" in lines
    end
  end

  describe "a Google series whose master was never read" do
    test "offers only this and following, from the occurrence's own start", %{
      conn: conn,
      user: user
    } do
      integration = oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar")

      event =
        occurrence(integration, %{
          provider: "google",
          uid: "weekly_20261014T090000Z",
          provider_event_id: "series1_20261014T090000Z",
          recurring_event_id: "series1"
        })

      lv = open(conn, event)
      pick(lv, %{"freq" => "monthly"})
      save(lv)

      assert prompt_summary(lv, :following) =~ @following_summary
      assert has_element?(lv, "#recurrence-prompt-modal [phx-value-scope='following']")
      refute has_element?(lv, "#recurrence-scope-all")
      refute has_element?(lv, "#recurrence-prompt-modal [phx-value-scope='all']")
    end
  end

  # Opens the occurrence, switches it to monthly, which the editor shows
  # from the series' start, and saves it into the scope prompt.
  defp stage_monthly_and_save(conn, event) do
    lv = open(conn, event)
    html = pick(lv, %{"freq" => "monthly"})
    assert html =~ @all_summary

    save(lv)

    assert has_element?(lv, "#recurrence-scope-all [data-role='scope-summary']", @all_summary)

    assert has_element?(
             lv,
             "#recurrence-scope-following [data-role='scope-summary']",
             @following_summary
           )

    lv
  end
end
