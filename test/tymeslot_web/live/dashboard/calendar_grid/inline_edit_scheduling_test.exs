defmodule TymeslotWeb.Dashboard.CalendarGrid.InlineEditSchedulingTest do
  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "all-day toggling" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      today = Date.utc_today()

      timed_event =
        insert_event(integration, %{
          summary: "Sprint Review",
          start_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(today, ~T[11:00:00], "Etc/UTC"),
          all_day: false
        })

      all_day_event =
        insert_event(integration, %{
          summary: "Company Offsite",
          start_at: nil,
          end_at: nil,
          start_date: today,
          # end_date is exclusive, so a single-day all-day event ends on the
          # following day.
          end_date: Date.add(today, 1),
          all_day: true
        })

      {:ok, timed_event: timed_event, all_day_event: all_day_event}
    end

    test "renders an all-day switch in the editable detail modal", %{
      conn: conn,
      timed_event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ ~s(id="event-all-day")
      assert html =~ "All day"
    end

    test "toggling a timed event to all-day shows the date-range editor", %{
      conn: conn,
      timed_event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("toggle_event_all_day", %{})

      assert html =~ ~s(id="event-all-day-form")
      assert html =~ ~s(id="event-all-day-start")
      refute html =~ ~s(id="event-time-form")
    end

    test "toggling an all-day event back to timed shows the time editor", %{
      conn: conn,
      all_day_event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#allday-event-#{event.id}") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("toggle_event_all_day", %{})

      assert html =~ ~s(id="event-time-form")
      refute html =~ ~s(id="event-all-day-form")
    end
  end

  describe "event reminders" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      today = Date.utc_today()

      event =
        insert_event(integration, %{
          summary: "Sprint Review",
          start_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(today, ~T[11:00:00], "Etc/UTC"),
          all_day: false,
          reminders: []
        })

      {:ok, integration: integration, event: event}
    end

    test "renders the reminders editor in the editable detail modal", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "Reminders"
      assert html =~ "Add reminder"
    end

    test "opens an event whose reminders were round-tripped through the cache", %{
      conn: conn,
      integration: integration
    } do
      today = Date.utc_today()

      # Reminders live in a JSONB column, so a synced reminder comes back
      # string-keyed however it was written.
      stored =
        insert_event(integration, %{
          summary: "Quarterly Planning",
          start_at: DateTime.new!(today, ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(today, ~T[15:00:00], "Etc/UTC"),
          all_day: false,
          reminders: [%{"method" => "popup", "minutes_before" => 30}]
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{stored.id}-']") |> render_click()

      assert html =~ "Notification 30 minutes before"
    end

    test "adding a reminder shows it in the editor (optimistic update)", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_event_reminder", %{"method" => "popup", "minutes" => "10"})

      assert html =~ "Notification 10 minutes before"
    end

    test "removing a reminder clears it from the editor", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("add_event_reminder", %{"method" => "email", "minutes" => "30"})

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("remove_event_reminder", %{"index" => "0"})

      refute html =~ "Email 30 minutes before"
    end

    test "rejects a lead time outside the allowed presets", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_event_reminder", %{"method" => "popup", "minutes" => "7"})

      refute html =~ "7 minutes before"
    end
  end

  describe "event recurrence editing" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)
      today = Date.utc_today()

      event =
        insert_event(integration, %{
          summary: "Standup",
          start_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(today, ~T[10:15:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, integration: integration, event: event}
    end

    test "renders the recurrence editor in the editable detail modal", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "Repeat"
      assert html =~ "Does not repeat"
    end

    test "setting a weekly repeat shows the summary (optimistic update)", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_recurrence", %{
          "freq" => "weekly",
          "interval" => "1",
          "by_day" => ["mo", "we"],
          "end_type" => "never"
        })

      assert html =~ "Repeats weekly on Mon, Wed"
    end

    test "editing the rule of a recurring series opens the scope prompt", %{
      conn: conn,
      integration: integration
    } do
      today = Date.utc_today()

      recurring =
        insert_event(integration, %{
          summary: "Recurring standup",
          start_at: DateTime.new!(today, ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(today, ~T[09:15:00], "Etc/UTC"),
          all_day: false,
          recurrence_rule: "FREQ=DAILY",
          recurring_event_id: "series-1"
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{recurring.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_recurrence", %{
          "freq" => "weekly",
          "interval" => "1",
          "by_day" => ["mo"],
          "end_type" => "never"
        })

      # The recurrence-scope prompt (this / this-and-following / all events) gates
      # the change rather than writing immediately.
      assert html =~ "confirm_recurrence_scope"
    end
  end

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
