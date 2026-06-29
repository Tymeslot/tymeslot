defmodule TymeslotWeb.Dashboard.CalendarGrid.AgendaViewTest do
  @moduledoc """
  Covers the agenda (schedule list) view: switching into it via `set_view`,
  the grouped-by-day rendering of upcoming events, and the empty state when the
  agenda window holds no events.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "agenda view" do
    test "renders upcoming events grouped under day headers", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      # Two events on different upcoming days, within the 30-day window.
      day_one = Date.add(Date.utc_today(), 2)
      day_two = Date.add(Date.utc_today(), 5)

      insert_event(integration, %{
        summary: "Quarterly Review",
        location: "Boardroom A",
        start_at: DateTime.new!(day_one, ~T[09:00:00], "Etc/UTC"),
        end_at: DateTime.new!(day_one, ~T[10:00:00], "Etc/UTC"),
        all_day: false
      })

      insert_event(integration, %{
        summary: "Design Workshop",
        start_at: DateTime.new!(day_two, ~T[14:00:00], "Etc/UTC"),
        end_at: DateTime.new!(day_two, ~T[15:30:00], "Etc/UTC"),
        all_day: false
      })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html = lv |> element("#calendar-grid") |> render_hook("set_view", %{"view" => "agenda"})

      # Both events render, each under its own day header.
      assert html =~ "Quarterly Review"
      assert html =~ "Boardroom A"
      assert html =~ "Design Workshop"

      assert html =~ Calendar.strftime(day_one, "%a %-d %B")
      assert html =~ Calendar.strftime(day_two, "%a %-d %B")

      # The agenda container is present and visible.
      assert html =~ "calendar-agenda"
    end

    test "renders all-day events with an 'All day' label", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)
      day = Date.add(Date.utc_today(), 3)

      insert_event(integration, %{
        summary: "Company Offsite",
        start_date: day,
        end_date: Date.add(day, 1),
        start_at: DateTime.new!(day, ~T[00:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.add(day, 1), ~T[00:00:00], "Etc/UTC"),
        all_day: true
      })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#calendar-grid") |> render_hook("set_view", %{"view" => "agenda"})

      assert html =~ "Company Offsite"
      assert html =~ "All day"
    end

    test "shows a friendly empty state when the window has no events", %{conn: conn, user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#calendar-grid") |> render_hook("set_view", %{"view" => "agenda"})

      assert html =~ "calendar-agenda"
      assert html =~ "No upcoming events"
    end

    test "skips past events outside the upcoming window", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)
      past_day = Date.add(Date.utc_today(), -3)

      insert_event(integration, %{
        summary: "Old Standup",
        start_at: DateTime.new!(past_day, ~T[09:00:00], "Etc/UTC"),
        end_at: DateTime.new!(past_day, ~T[09:30:00], "Etc/UTC"),
        all_day: false
      })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#calendar-grid") |> render_hook("set_view", %{"view" => "agenda"})

      refute html =~ "Old Standup"
      assert html =~ "No upcoming events"
    end

    test "all-day events on the same day render in stable alphabetical order", %{
      conn: conn,
      user: user
    } do
      integration = insert(:calendar_integration, user: user, is_active: true)
      # Choose a day outside the default week view (today..+6) but inside the
      # 30-day agenda window, so only the agenda renders these events — the
      # whole-page match would otherwise also see the week all-day row.
      day = Date.add(Date.utc_today(), 20)

      # Insert in reverse alphabetical order — stable sort must normalise this.
      insert_event(integration, %{
        summary: "Zeta Conference",
        start_date: day,
        end_date: Date.add(day, 1),
        start_at: DateTime.new!(day, ~T[00:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.add(day, 1), ~T[00:00:00], "Etc/UTC"),
        all_day: true
      })

      insert_event(integration, %{
        summary: "Alpha Offsite",
        start_date: day,
        end_date: Date.add(day, 1),
        start_at: DateTime.new!(day, ~T[00:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.add(day, 1), ~T[00:00:00], "Etc/UTC"),
        all_day: true
      })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#calendar-grid") |> render_hook("set_view", %{"view" => "agenda"})

      # The month/week views are always present in the DOM (just hidden), so
      # scope the assertion to the agenda container to test its ordering alone.
      [_before, agenda_html] = String.split(html, ~s(id="calendar-agenda"), parts: 2)

      alpha_pos = elem(:binary.match(agenda_html, "Alpha Offsite"), 0)
      zeta_pos = elem(:binary.match(agenda_html, "Zeta Conference"), 0)

      assert alpha_pos < zeta_pos,
             "Alpha Offsite should appear before Zeta Conference in the rendered output"
    end
  end

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
