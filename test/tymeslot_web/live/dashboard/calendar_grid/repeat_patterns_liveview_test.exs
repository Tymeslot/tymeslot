defmodule TymeslotWeb.Dashboard.CalendarGrid.RepeatPatternsLiveViewTest do
  @moduledoc """
  The grid's repeat editor building the patterns Google and Outlook can
  express, end to end: what reaches the provider, what is left alone, and
  where no repeat is offered at all.

  As in `RecurringScopeLiveViewTest`, the `:calendar_module` seam and the
  provider API modules point back at the runtime modules, so only the HTTP
  client is mocked.
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
  import Tymeslot.Test.ClockHelpers, only: [freeze_clock_midweek: 0]

  alias Plug.Test
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.Recurrence.Pattern
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Security.Encryption
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceSummary

  setup do: freeze_clock_midweek()

  setup :set_mox_global
  setup :verify_on_exit!

  # The provider write runs in a Task; allow for a busy test machine.
  @task_timeout 5_000

  @tokens ~w(mo tu we th fr sa su)
  @graph_days ~w(monday tuesday wednesday thursday friday saturday sunday)
  @graph_index %{1 => "first", 2 => "second", 3 => "third", 4 => "fourth", -1 => "last"}

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
    swap_env(:outlook_calendar_api_module, OutlookAPI)

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    {:ok, conn: conn, user: user}
  end

  defp today, do: Clock.utc_today()
  defp first_day, do: Date.add(today(), -14)
  defp at_today(hour), do: DateTime.new!(today(), Time.new!(hour, 0, 0), "Etc/UTC")
  defp today_token, do: Enum.at(@tokens, Date.day_of_week(today()) - 1)

  # The weekday position today is in its month: the second Tuesday, or the
  # last Friday when it is a fifth.
  defp today_position, do: position(today())

  # The same, for the series' first start: a rule for a whole series is
  # built from it.
  defp first_day_position, do: position(first_day())

  defp position(date) do
    Enum.find(
      Pattern.choices(date),
      &match?({_ordinal, kind} when is_atom(kind) and kind in ~w(mo tu we th fr sa su)a, &1)
    )
  end

  describe "an occurrence of an Outlook series" do
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          refresh_token_encrypted: Encryption.encrypt("refresh_token"),
          token_expires_at: DateTime.add(Clock.utc_now(), 3600),
          oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite"
        )

      # Stamped with its series' rule as the sync caches it, Outlook's own
      # spelling: an end date with no time.
      until = today() |> Date.add(60) |> Calendar.strftime("%Y%m%d")

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "outlook",
          provider_calendar_id: "team-calendar",
          uid: "weekly-occurrence-today",
          provider_event_id: "occurrence-1",
          recurring_event_id: "master-1",
          provider_metadata: %{"type" => "occurrence"},
          summary: "Weekly sync",
          start_at: at_today(9),
          end_at: at_today(10),
          all_day: false,
          timezone: "Etc/UTC",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=#{String.upcase(today_token())};UNTIL=#{until}",
          sync_state: "synced"
        )

      # Read with the master's start, which a rule for the whole series is
      # written against.
      {:ok, _row} =
        SeriesRuleQueries.put(integration.id, "master-1", %{
          rule: event.recurrence_rule,
          master_start: DateTime.new!(first_day(), ~T[09:00:00], "Etc/UTC"),
          fetched_at: DateTime.utc_now()
        })

      serve(outlook_master())
      %{event: event, until: Date.add(today(), 60)}
    end

    test "a monthly pattern on the series' weekday position reaches Outlook as a relative one", %{
      conn: conn,
      event: event
    } do
      {ordinal, kind} = first_day_position()
      lv = open(conn, event)

      change_recurrence(lv, %{
        "freq" => "monthly",
        "interval" => "1",
        "on" => "#{ordinal}:#{kind}",
        "end_type" => "never"
      })

      confirm_scope(lv, "all")

      assert [{:get, _master, _read}, {:patch, _url, body}] = await_requests(2)

      assert %{
               "type" => "relativeMonthly",
               "index" => index,
               "daysOfWeek" => [day]
             } = Jason.decode!(body)["recurrence"]["pattern"]

      assert index == Map.fetch!(@graph_index, ordinal)
      assert day == Enum.at(@graph_days, Enum.find_index(@tokens, &(&1 == to_string(kind))))
    end

    # The rule Outlook wrote ends on a date; the editor's ends on the instant
    # that date ends. They are the same series, so nothing is written.
    test "the rule it already has, read back through the editor, is not written", %{
      conn: conn,
      event: event,
      until: until
    } do
      lv = open(conn, event)

      change_recurrence(lv, %{
        "freq" => "weekly",
        "interval" => "1",
        "by_day" => [today_token()],
        "end_type" => "until",
        "until" => Date.to_iso8601(until)
      })

      refute has_element?(lv, "#recurrence-prompt-modal")
      refute_receive {:request, _method, _url, _body}, 200
    end
  end

  describe "editing a CalDAV weekly series" do
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://caldav.example.com",
          calendar_paths: ["/cal/"]
        )

      rule = "FREQ=WEEKLY;BYDAY=#{String.upcase(today_token())}"
      %{event: caldav_series(integration, rule)}
    end

    test "shows its pattern, and every other week on one more day reaches the server", %{
      conn: conn,
      event: event
    } do
      lv = open(conn, event)
      other = Enum.find(@tokens, &(&1 != today_token()))

      assert render(lv) =~ "Repeats weekly on #{weekday_label(today_token())}"

      expect_puts(1)
      html = pick(lv, %{"interval" => "2", "by_day" => [other]})
      confirm_scope(lv, "all")

      assert html =~ "Repeats every 2 weeks on"
      assert [{_url, body}] = await_puts(1)

      assert rrule(body) ==
               "FREQ=WEEKLY;INTERVAL=2;BYDAY=" <>
                 (@tokens
                  |> Enum.filter(&(&1 in [today_token(), other]))
                  |> Enum.map_join(",", &String.upcase/1))

      settle(lv)
    end

    # The number field appears only once the end is picked, so the pick
    # starts from ten rather than reading back as "Never ends".
    test "picking an end after a number of times starts from ten", %{
      conn: conn,
      event: event
    } do
      lv = open(conn, event)

      expect_puts(1)
      html = pick(lv, %{"end_type" => "count"})

      assert html =~ "for 10 occurrences"

      assert has_element?(
               lv,
               "#recurrence-editor-form-update_event_recurrence [name='count'][value='10']"
             )

      confirm_scope(lv, "all")
      assert [{_url, body}] = await_puts(1)
      assert rrule(body) =~ ";COUNT=10"
      settle(lv)
    end

    test "picking an end on a date starts from the tenth occurrence's day", %{
      conn: conn,
      event: event
    } do
      lv = open(conn, event)

      # Ten weekly occurrences from the series' first start.
      tenth = Date.add(first_day(), 9 * 7)

      expect_puts(1)
      pick(lv, %{"end_type" => "until"})

      assert has_element?(
               lv,
               "#recurrence-editor-form-update_event_recurrence [name='until'][value='#{Date.to_iso8601(tenth)}']"
             )

      confirm_scope(lv, "all")
      assert [{_url, body}] = await_puts(1)
      assert rrule(body) =~ ";UNTIL=#{Calendar.strftime(tenth, "%Y%m%d")}T235959Z"
      settle(lv)
    end
  end

  describe "editing a CalDAV series that ends after a number of times" do
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://caldav.example.com",
          calendar_paths: ["/cal/"]
        )

      rule = "FREQ=WEEKLY;BYDAY=#{String.upcase(today_token())};COUNT=10"
      %{event: caldav_series(integration, rule)}
    end

    test "takes the number typed", %{conn: conn, event: event} do
      lv = open(conn, event)

      assert render(lv) =~ "for 10 occurrences"

      expect_puts(1)
      html = pick(lv, %{"count" => "6"})
      assert html =~ "for 6 occurrences"
      confirm_scope(lv, "all")

      assert [{_url, body}] = await_puts(1)
      assert rrule(body) == "FREQ=WEEKLY;BYDAY=#{String.upcase(today_token())};COUNT=6"
      settle(lv)
    end
  end

  describe "an Exchange event" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, provider: "exchange")

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "exchange",
          uid: "exchange-event",
          provider_event_id: "AAMkExchange",
          summary: "Planning",
          start_at: at_today(9),
          end_at: at_today(10),
          all_day: false,
          sync_state: "synced"
        )

      %{event: event}
    end

    # Exchange writes from the grid carry no repeat rule.
    test "offers no repeat controls", %{conn: conn, event: event} do
      lv = open(conn, event)

      refute has_element?(lv, "#recurrence-editor-form-update_event_recurrence")

      change_recurrence(lv, %{"freq" => "daily", "interval" => "1", "end_type" => "never"})
      refute has_element?(lv, "#recurrence-prompt-modal")
    end

    test "a new event on it offers no repeat controls", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("show_create_form", %{})

      assert has_element?(lv, "#create-event-modal")
      refute has_element?(lv, "#recurrence-editor-form-update_create_recurrence")
    end
  end

  describe "a CalDAV series" do
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://caldav.example.com",
          calendar_paths: ["/cal/"]
        )

      %{integration: integration}
    end

    # Two positions of today's weekday each month (the second and the first
    # Wednesday, say): no pattern the editor builds, and today one of them.
    test "with a rule the editor cannot build shows it, and a title edit keeps it", %{
      conn: conn,
      integration: integration
    } do
      {ordinal, _kind} = today_position()
      other = if ordinal == 1, do: 3, else: 1
      rule = "FREQ=MONTHLY;BYDAY=#{ordinal}#{today_token()},#{other}#{today_token()}"
      event = caldav_series(integration, rule)
      lv = open(conn, event)

      assert render(lv) =~ "Repeats on a custom pattern"

      assert has_element?(
               lv,
               "#recurrence-custom-update_event_recurrence button",
               "Replace repeat rule"
             )

      expect_puts(1)

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed standup"})

      assert [{_url, body}] = await_puts(1)
      lines = LineFolder.unfold_lines(body)
      assert "SUMMARY:Renamed standup" in lines
      assert ("RRULE:" <> rule) in lines
    end

    # "Replace repeat rule" reveals the controls on the client; they are in
    # the page, hidden, from the start, and picking a pattern in them
    # replaces the rule.
    test "with a rule the editor cannot build is replaced by the pattern picked", %{
      conn: conn,
      integration: integration
    } do
      {ordinal, _kind} = today_position()
      other = if ordinal == 1, do: 3, else: 1
      rule = "FREQ=MONTHLY;BYDAY=#{ordinal}#{today_token()},#{other}#{today_token()}"
      event = caldav_series(integration, rule)
      lv = open(conn, event)

      expect_puts(1)
      html = pick(lv, %{"freq" => "weekly"})

      assert html =~ "Repeats weekly on #{weekday_label(today_token())}"
      refute has_element?(lv, "#recurrence-custom-update_event_recurrence")

      confirm_scope(lv, "all")

      assert [{_url, body}] = await_puts(1)
      # The weekday boxes appear once the pattern is weekly, so none was
      # sent: a weekly rule with no day repeats on its start's weekday.
      assert rrule(body) == "FREQ=WEEKLY"
      settle(lv)
    end

    # Its rule is one the editor wrote: it reads back as the pattern it is.
    test "with a rule the editor built reads it back as that pattern", %{
      conn: conn,
      integration: integration
    } do
      # Built from the series' first start, which it is read from.
      {ordinal, kind} = first_day_position()
      rule = Pattern.build(%{freq: :monthly, on: {ordinal, kind}}, first_day())
      event = caldav_series(integration, rule)
      lv = open(conn, event)

      refute has_element?(lv, "#recurrence-custom-update_event_recurrence")

      assert has_element?(
               lv,
               "#recurrence-editor-form-update_event_recurrence option[value='#{ordinal}:#{kind}'][selected]"
             )
    end
  end

  defp caldav_series(integration, rule) do
    first = Calendar.strftime(first_day(), "%Y%m%d")

    ical =
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "VERSION:2.0",
          "BEGIN:VEVENT",
          "UID:monthly-standup",
          "DTSTAMP:20260901T090000Z",
          "DTSTART:#{first}T090000Z",
          "DTEND:#{first}T100000Z",
          "RRULE:" <> rule,
          "SUMMARY:Monthly standup",
          "END:VEVENT",
          "END:VCALENDAR"
        ],
        "\r\n"
      ) <> "\r\n"

    insert(:provider_calendar_event,
      calendar_integration: integration,
      uid: "monthly-standup_#{Calendar.strftime(today(), "%Y%m%dT090000")}",
      provider: "caldav",
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/monthly-standup.ics",
      summary: "Monthly standup",
      start_at: at_today(9),
      end_at: at_today(10),
      all_day: false,
      timezone: "Etc/UTC",
      recurrence_rule: rule,
      provider_metadata: %{"uid" => "monthly-standup"},
      etag: "\"etag-1\"",
      raw_ical: ical,
      sync_state: "synced"
    )
  end

  defp outlook_master do
    first = Date.to_iso8601(first_day())

    %{
      "id" => "master-1",
      "type" => "seriesMaster",
      "subject" => "Weekly sync",
      "isAllDay" => false,
      "start" => %{"dateTime" => "#{first}T09:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "#{first}T10:00:00.0000000", "timeZone" => "UTC"},
      "originalStartTimeZone" => "UTC",
      "recurrence" => %{
        "pattern" => %{
          "type" => "weekly",
          "interval" => 1,
          "daysOfWeek" => [Enum.at(@graph_days, Date.day_of_week(today()) - 1)]
        },
        "range" => %{"type" => "noEnd", "startDate" => first}
      }
    }
  end

  defp serve(master) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:request, method, url, body})
      {:ok, %Req.Response{status: 200, body: Jason.encode!(master)}}
    end)
  end

  defp await_requests(count) do
    for _request <- 1..count do
      assert_receive {:request, method, url, body}, @task_timeout
      {method, url, body}
    end
  end

  defp expect_puts(count) do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, count, fn url, body, _headers, _opts ->
      send(test_pid, {:put, url, body})
      {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
    end)
  end

  defp await_puts(count) do
    for _put <- 1..count do
      assert_receive {:put, url, body}, @task_timeout
      {url, body}
    end
  end

  defp open(conn, event) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})

    lv
  end

  defp pick(lv, fields) do
    lv
    |> form("#recurrence-editor-form-update_event_recurrence", fields)
    |> render_change()
  end

  # A write to a whole series closes the event once it has answered; wait
  # for it, so the write does not outlive the test's database sandbox.
  defp settle(lv) do
    eventually(
      fn -> not has_element?(lv, "#recurrence-editor-form-update_event_recurrence") end,
      timeout: @task_timeout
    )
  end

  defp rrule(ical_body) do
    ical_body
    |> LineFolder.unfold_lines()
    |> Enum.find_value(fn line ->
      case line do
        "RRULE:" <> rule -> rule
        _other -> nil
      end
    end)
  end

  defp weekday_label(token),
    do: RecurrenceSummary.weekday_label(String.to_existing_atom(token))

  defp change_recurrence(lv, params) do
    lv
    |> element("#calendar-grid")
    |> render_hook("update_event_recurrence", params)
  end

  # The editor stages a pattern; saving it asks for the scope.
  defp confirm_scope(lv, scope) do
    unless has_element?(lv, "#recurrence-prompt-modal") do
      lv
      |> element("button[phx-click='save_event_recurrence']")
      |> render_click()
    end

    lv
    |> element("#recurrence-prompt-modal [phx-value-scope='#{scope}']")
    |> render_click()
  end
end
