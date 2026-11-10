defmodule TymeslotWeb.Dashboard.CalendarGrid.DesktopRemindersLiveViewTest do
  @moduledoc """
  LiveView coverage for the desktop-reminder feed the calendar page hands to the
  browser. The user-level action is "keep the calendar open and get a desktop
  notification before each event I can see".
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    {:ok, _prefs} = CalendarPreferencesQueries.upsert(user.id, %{desktop_reminders_enabled: true})

    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  # A deselected calendar's rows stay cached until pruning runs, so the feed has
  # to honour the selection itself, as the grid does.
  test "omits events from a calendar the user has deselected", %{conn: conn, user: user} do
    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        is_active: true,
        calendar_paths: ["/cal/work/"],
        calendar_list: [
          %{"id" => "/cal/work/", "path" => "/cal/work/", "selected" => true},
          %{"id" => "/cal/personal/", "path" => "/cal/personal/", "selected" => false}
        ]
      )

    start_at = DateTime.add(DateTime.utc_now(), 2, :day)

    for {summary, path} <- [{"Work Meeting", "/cal/work/"}, {"Personal Errand", "/cal/personal/"}] do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: summary,
        start_at: start_at,
        end_at: DateTime.add(start_at, 1, :hour),
        all_day: false,
        provider_event_id: path <> "evt.ics",
        reminders: [%{"method" => "popup", "minutes_before" => 10}]
      )
    end

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    feed = lv |> element("#desktop-reminders") |> render()

    assert feed =~ "Work Meeting"
    refute feed =~ "Personal Errand"
  end

  describe "switching reminders on from the settings modal" do
    setup %{conn: conn, user: user} do
      {:ok, _prefs} =
        CalendarPreferencesQueries.upsert(user.id, %{desktop_reminders_enabled: false})

      %{lv: open_settings(conn)}
    end

    test "a granted permission saves the preference as on", %{lv: lv, user: user} do
      component_event(lv, "desktop_reminders_permission", %{"permission" => "default"})
      refute reminders_on?(user)

      html = component_event(lv, "enable_desktop_reminders", %{"permission" => "granted"})

      assert reminders_on?(user)
      assert has_element?(lv, ~s(#desktop-reminders-switch[aria-checked="true"]))
      refute html =~ "desktop-permission-note"
    end

    test "a refused permission leaves the switch off and says so", %{lv: lv, user: user} do
      html = component_event(lv, "enable_desktop_reminders", %{"permission" => "denied"})

      refute reminders_on?(user)
      assert has_element?(lv, ~s(#desktop-reminders-switch[aria-checked="false"]))
      assert html =~ "Blocked in your browser settings"
    end

    test "a dismissed prompt leaves the switch off without calling it blocked", %{
      lv: lv,
      user: user
    } do
      html = component_event(lv, "enable_desktop_reminders", %{"permission" => "default"})

      refute reminders_on?(user)
      assert html =~ "Notifications were not allowed, so reminders are still off."
      refute html =~ "Blocked in your browser settings"
    end

    test "a browser without notifications cannot switch them on", %{lv: lv, user: user} do
      html = component_event(lv, "enable_desktop_reminders", %{"permission" => "unsupported"})

      refute reminders_on?(user)
      assert html =~ "This browser does not support notifications."
    end

    test "an unknown permission value is ignored", %{lv: lv, user: user} do
      component_event(lv, "enable_desktop_reminders", %{"permission" => "maybe"})

      refute reminders_on?(user)
    end

    test "the plain toggle cannot turn reminders on, whatever the hook did", %{lv: lv, user: user} do
      # The hook is lazy-loaded: a click before it arrives, or after a failed
      # import, reaches the server as the plain toggle.
      lv |> element("#desktop-reminders-switch") |> render_click()

      refute reminders_on?(user)
      assert has_element?(lv, ~s(#desktop-reminders-switch[aria-checked="false"]))
    end

    test "the plain toggle still turns reminders off", %{lv: lv, user: user} do
      component_event(lv, "enable_desktop_reminders", %{"permission" => "granted"})
      assert reminders_on?(user)

      lv |> element("#desktop-reminders-switch") |> render_click()

      refute reminders_on?(user)
      assert has_element?(lv, ~s(#desktop-reminders-switch[aria-checked="false"]))
    end

    test "the switch hands the click to the permission hook", %{lv: lv} do
      html = lv |> element("#desktop-reminders-switch") |> render()

      assert html =~ ~s(phx-hook="DesktopReminderPermission")
    end
  end

  describe "a preference saved before the switch asked for permission" do
    test "offers an Allow notifications button while the browser has not answered", %{
      conn: conn
    } do
      lv = open_settings(conn)
      html = component_event(lv, "desktop_reminders_permission", %{"permission" => "default"})

      assert html =~ "Reminders are on, but your browser has not allowed notifications yet."
      assert has_element?(lv, "#desktop-reminders-grant", "Allow notifications")
    end

    test "says blocked when the browser has denied it", %{conn: conn} do
      lv = open_settings(conn)
      html = component_event(lv, "desktop_reminders_permission", %{"permission" => "denied"})

      assert html =~ "Blocked in your browser settings"
      refute has_element?(lv, "#desktop-reminders-grant")
    end

    test "shows nothing once permission is granted", %{conn: conn} do
      lv = open_settings(conn)
      html = component_event(lv, "desktop_reminders_permission", %{"permission" => "granted"})

      refute html =~ "desktop-permission-note"
    end
  end

  defp component_event(lv, event, params) do
    lv |> element("#desktop-reminders-switch") |> render_hook(event, params)
  end

  defp reminders_on?(user) do
    CalendarPreferencesQueries.get_or_create(user.id).desktop_reminders_enabled
  end

  defp open_settings(conn) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("button[phx-click='toggle_settings']") |> render_click()
    lv
  end
end
