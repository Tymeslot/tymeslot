defmodule TymeslotWeb.Dashboard.CalendarGrid.RepeatEditorCreateLiveViewTest do
  @moduledoc """
  Building each repeat pattern in the create form, end to end: the organiser
  picks it in the editor's controls, reads it back in the summary, saves, and
  the rule reaches Google or Outlook.

  The controls are driven through `form/3`, which refuses a field or option
  the form does not render, so each journey also proves the editor offers
  what it picks.

  As in `RepeatPatternsLiveViewTest`, the `:calendar_module` seam and the
  provider API modules point back at the runtime modules, so only the HTTP
  client is mocked.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Security.Encryption

  setup :set_mox_global
  setup :verify_on_exit!

  # The provider write runs in a Task; allow for a busy test machine.
  @task_timeout 5_000

  @form "#recurrence-editor-form-update_create_recurrence"

  # November 2026 starts on a Sunday: the 10th is its second Tuesday, the
  # 24th both its fourth and its last, and the 30th, a Monday, its last
  # weekday and its last day.
  @second_tuesday "2026-11-10"
  @last_tuesday "2026-11-24"
  @last_weekday "2026-11-30"

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

  defp oauth_calendar(user, provider, scope) do
    insert(:calendar_integration,
      user: user,
      provider: provider,
      access_token_encrypted: Encryption.encrypt("valid_token"),
      refresh_token_encrypted: Encryption.encrypt("refresh_token"),
      token_expires_at: DateTime.add(Clock.utc_now(), 3600),
      oauth_scope: scope,
      default_booking_calendar_id: "primary",
      is_active: true
    )
  end

  describe "a new event on a Google calendar" do
    setup %{user: user} do
      oauth_calendar(user, "google", "https://www.googleapis.com/auth/calendar")
      serve(%{"id" => "created-1", "status" => "confirmed"})
      :ok
    end

    test "repeats every few days and ends after a number of times", %{conn: conn} do
      lv = open_create(conn, @second_tuesday)

      pick(lv, %{"freq" => "daily"})
      html = pick(lv, %{"interval" => "3", "end_type" => "count"})
      assert html =~ ~s(name="count")
      html = pick(lv, %{"count" => "5"})

      assert html =~ "Repeats every 3 days for 5 occurrences"

      assert %RRule{freq: :daily, interval: 3, count: 5, until: nil, by_day: nil} =
               save_to_google(lv)
    end

    test "repeats every other week on several days until a date", %{conn: conn} do
      lv = open_create(conn, @second_tuesday)

      pick(lv, %{"freq" => "weekly"})
      pick(lv, %{"interval" => "2", "by_day" => ["th"], "end_type" => "until"})
      html = pick(lv, %{"until" => "2027-02-01"})

      assert html =~ "Repeats every 2 weeks on Tue, Thu until 1 February 2027"

      assert %RRule{freq: :weekly, interval: 2, by_day: [{nil, 2}, {nil, 4}], until: until} =
               save_to_google(lv)

      # The end date's whole day, in the organiser's zone.
      assert until == "20270201T235959Z"
    end

    test "a weekly pattern always repeats on the start's weekday", %{conn: conn} do
      lv = open_create(conn, @second_tuesday)

      pick(lv, %{"freq" => "weekly"})
      html = pick(lv, %{"by_day" => ["fr"]})

      assert html =~ "Repeats weekly on Tue, Fri"
      assert %RRule{freq: :weekly, by_day: [{nil, 2}, {nil, 5}]} = save_to_google(lv)
    end

    test "repeats monthly on the start's day of the month", %{conn: conn} do
      lv = open_create(conn, @second_tuesday)

      html = pick(lv, %{"freq" => "monthly"})

      assert html =~ "Repeats monthly on day 10"

      assert %RRule{freq: :monthly, by_day: nil, by_month_day: nil, by_set_pos: nil} =
               save_to_google(lv)
    end

    test "repeats monthly on the nth weekday the start is", %{conn: conn} do
      lv = open_create(conn, @second_tuesday)

      pick(lv, %{"freq" => "monthly"})
      html = pick(lv, %{"on" => "2:tu"})

      assert html =~ "Repeats monthly on the second Tuesday"
      assert %RRule{freq: :monthly, by_day: [{2, 2}], by_set_pos: nil} = save_to_google(lv)
    end

    test "repeats monthly on the last weekday of its kind", %{conn: conn} do
      lv = open_create(conn, @last_tuesday)

      pick(lv, %{"freq" => "monthly"})
      html = pick(lv, %{"on" => "-1:tu"})

      assert html =~ "Repeats monthly on the last Tuesday"
      assert %RRule{freq: :monthly, by_day: [{-1, 2}]} = save_to_google(lv)
    end

    test "repeats monthly on the last weekday of the month", %{conn: conn} do
      lv = open_create(conn, @last_weekday)

      pick(lv, %{"freq" => "monthly"})
      html = pick(lv, %{"on" => "-1:weekday"})

      assert html =~ "Repeats monthly on the last weekday"

      assert %RRule{freq: :monthly, by_day: by_day, by_set_pos: [-1]} = save_to_google(lv)
      assert by_day == for(day <- 1..5, do: {nil, day})
    end

    test "repeats yearly on the start's date", %{conn: conn} do
      lv = open_create(conn, @second_tuesday)

      pick(lv, %{"freq" => "yearly"})
      html = pick(lv, %{"interval" => "2"})

      assert html =~ "Repeats every 2 years on 10 November"

      assert %RRule{freq: :yearly, interval: 2, by_day: nil, by_month: nil} =
               save_to_google(lv)
    end

    test "repeats yearly on the nth weekday of the start's month", %{conn: conn} do
      lv = open_create(conn, @second_tuesday)

      pick(lv, %{"freq" => "yearly"})
      html = pick(lv, %{"on" => "2:tu"})

      assert html =~ "Repeats yearly on the second Tuesday of November"
      assert %RRule{freq: :yearly, by_day: [{2, 2}], by_month: [11]} = save_to_google(lv)
    end

    # The choices follow the start: a date that is not the second Tuesday
    # cannot repeat on it, so the pattern takes the date's own weekday at
    # its position, the second Wednesday.
    test "moving the start to another day re-anchors a monthly position", %{conn: conn} do
      lv = open_create(conn, @second_tuesday)

      pick(lv, %{"freq" => "monthly"})
      pick(lv, %{"on" => "2:tu"})

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_create_time", %{
          "start-date" => "2026-11-11",
          "end-date" => "2026-11-11"
        })

      assert html =~ "Repeats monthly on the second Wednesday"
      refute has_element?(lv, "#{@form} option[value='2:tu']")
      assert has_element?(lv, "#{@form} option[value='2:we'][selected]")

      assert %RRule{freq: :monthly, by_day: [{2, 3}]} = save_to_google(lv)
    end

    test "back to Does not repeat saves a single event", %{conn: conn} do
      lv = open_create(conn, @second_tuesday)

      pick(lv, %{"freq" => "weekly"})
      html = pick(lv, %{"freq" => ""})

      refute html =~ "Repeats weekly"
      refute has_element?(lv, "#{@form} [name='interval']")

      body = save(lv)
      refute Map.has_key?(body, "recurrence")
    end
  end

  describe "a new event on an Outlook calendar" do
    setup %{user: user} do
      oauth_calendar(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")
      serve(%{"id" => "created-1", "iCalUId" => "ical-created-1"})
      :ok
    end

    test "a yearly pattern on the nth weekday is written as a relative yearly one", %{
      conn: conn
    } do
      lv = open_create(conn, @second_tuesday)

      pick(lv, %{"freq" => "yearly"})
      pick(lv, %{"on" => "2:tu", "end_type" => "count"})
      pick(lv, %{"count" => "4"})

      assert %{
               "pattern" => %{
                 "type" => "relativeYearly",
                 "index" => "second",
                 "daysOfWeek" => ["tuesday"],
                 "month" => 11,
                 "interval" => 1
               },
               "range" => %{"type" => "numbered", "numberOfOccurrences" => 4}
             } = save(lv)["recurrence"]
    end

    test "the last weekday of the month is written as a relative monthly one", %{conn: conn} do
      lv = open_create(conn, @last_weekday)

      pick(lv, %{"freq" => "monthly"})
      pick(lv, %{"on" => "-1:weekday", "end_type" => "until"})
      pick(lv, %{"until" => "2027-06-30"})

      assert %{
               "pattern" => %{
                 "type" => "relativeMonthly",
                 "index" => "last",
                 "daysOfWeek" => ~w(monday tuesday wednesday thursday friday)
               },
               "range" => %{"type" => "endDate", "endDate" => "2027-06-30"}
             } = save(lv)["recurrence"]
    end

    test "a yearly pattern on the start's date is written as an absolute yearly one", %{
      conn: conn
    } do
      lv = open_create(conn, @second_tuesday)

      pick(lv, %{"freq" => "yearly"})

      assert %{
               "pattern" => %{"type" => "absoluteYearly", "dayOfMonth" => 10, "month" => 11},
               "range" => %{"type" => "noEnd"}
             } = save(lv)["recurrence"]
    end
  end

  describe "a new event on an Outlook calendar, on a day some months lack" do
    setup %{user: user} do
      oauth_calendar(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")
      serve(%{"id" => "created-1"})
      :ok
    end

    # Graph would move the 31st of a shorter month to its last day, which is
    # not the pattern picked: the editor says so before the save refuses it.
    test "says why Outlook refuses the pattern, and the save writes nothing", %{conn: conn} do
      lv = open_create(conn, "2026-12-31")

      html = pick(lv, %{"freq" => "monthly"})
      assert html =~ "Repeats monthly on day 31"
      assert has_element?(lv, "#{@form} ~ [role='alert']", "Outlook can't skip the months")

      lv |> element("#calendar-grid") |> render_hook("save_event", %{})
      refute_receive {:request, :post, _url, _body}, 300
    end

    test "says nothing for a pattern Outlook takes", %{conn: conn} do
      lv = open_create(conn, "2026-12-31")
      pick(lv, %{"freq" => "weekly"})

      refute has_element?(lv, "[role='alert']", "Outlook can't skip the months")
    end
  end

  defp open_create(conn, date) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-grid")
    |> render_hook("show_create_form", %{
      "date" => date,
      "start-hour" => "9",
      "start-minute" => "0",
      "end-hour" => "10",
      "end-minute" => "0"
    })

    lv
    |> element("#calendar-grid")
    |> render_hook("update_create_title", %{"value" => "Review"})

    assert has_element?(lv, @form)
    lv
  end

  defp pick(lv, fields), do: lv |> form(@form, fields) |> render_change()

  defp save(lv) do
    lv |> element("#calendar-grid") |> render_hook("save_event", %{})

    assert_receive {:request, :post, _url, body}, @task_timeout
    # The create task caches the new event once the provider answers.
    eventually(fn -> render(lv) =~ "Event created." end, timeout: @task_timeout)
    Jason.decode!(body)
  end

  defp save_to_google(lv) do
    assert ["RRULE:" <> rule] = save(lv)["recurrence"]
    {:ok, parsed} = RRule.parse(rule)
    parsed
  end

  defp serve(response) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:request, method, url, body})
      {:ok, %Req.Response{status: 200, body: Jason.encode!(response)}}
    end)
  end
end
