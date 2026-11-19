defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceDesktopPermissionTest do
  @moduledoc """
  Desktop notifications are switched on only with the browser's permission.
  The `DesktopReminderPermission` hook on the display options' switch asks
  inside the click and pushes the answer (`calendar:enable_desktop_reminders`),
  and reports the current permission when it mounts
  (`calendar:desktop_permission`); the command bar's row pushes the same
  answer from its own gesture. These tests send those pushes as the hook
  would and check what is saved and what the organiser is told.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  @switch "#calendar-desktop-reminders"
  @note "#calendar-desktop-permission-note"

  defp open_display_options(lv),
    do: lv |> element("#calendar-display-options > button") |> render_click()

  defp answer(lv, permission, extra \\ %{}),
    do:
      lv
      |> element(@switch)
      |> render_hook(
        "calendar:enable_desktop_reminders",
        Map.put(extra, "permission", permission)
      )

  defp report(lv, permission),
    do:
      lv
      |> element(@switch)
      |> render_hook("calendar:desktop_permission", %{"permission" => permission})

  defp enabled?(user),
    do: CalendarPreferencesQueries.get_or_create(user.id).desktop_reminders_enabled

  defp displayed(conn, opts \\ []) do
    %{conn: conn, user: user} = owner(conn, opts)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_display_options(lv)
    {lv, user}
  end

  describe "switching on" do
    test "the switch carries the permission hook in both placements", %{conn: conn} do
      {lv, _user} = displayed(conn)

      assert has_element?(
               lv,
               "#{@switch}[phx-hook='DesktopReminderPermission'][data-enable-event='calendar:enable_desktop_reminders'][data-report-event='calendar:desktop_permission']"
             )

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:toggle_menu", %{"menu" => "calendars"})

      assert has_element?(
               lv,
               "#calendar-sheet-desktop-reminders[phx-hook='DesktopReminderPermission']"
             )
    end

    test "is saved once the browser allows notifications", %{conn: conn} do
      {lv, user} = displayed(conn)

      answer(lv, "granted")

      assert enabled?(user)
      assert has_element?(lv, "#{@switch}[aria-checked='true']")
      refute has_element?(lv, @note)
    end

    test "a blocked browser leaves them off and says where to allow them", %{conn: conn} do
      {lv, user} = displayed(conn)

      answer(lv, "denied")

      refute enabled?(user)
      assert has_element?(lv, "#{@switch}[aria-checked='false']")
      assert has_element?(lv, @note, "Blocked in your browser settings.")
    end

    test "a dismissed prompt leaves them off and says so", %{conn: conn} do
      {lv, user} = displayed(conn)

      answer(lv, "default")

      refute enabled?(user)

      assert has_element?(
               lv,
               @note,
               "Your browser did not allow notifications, so desktop notifications are still off."
             )
    end

    test "a browser without notifications leaves them off and says so", %{conn: conn} do
      {lv, user} = displayed(conn)

      answer(lv, "unsupported")

      refute enabled?(user)
      assert has_element?(lv, @note, "This browser does not support notifications.")
    end

    test "a plain toggle while off saves nothing", %{conn: conn} do
      {lv, user} = displayed(conn)

      lv |> element(@switch) |> render_click()

      refute enabled?(user)
      assert has_element?(lv, "#{@switch}[aria-checked='false']")
    end

    test "a refusal from the command bar is told in the toast", %{conn: conn} do
      {lv, user} = displayed(conn)

      answer(lv, "denied", %{"source" => "command"})

      refute enabled?(user)
      assert has_element?(lv, "#calendar-toast", "Blocked in your browser settings.")
    end

    test "a refusal from the switch is not repeated in the toast", %{conn: conn} do
      {lv, _user} = displayed(conn)

      answer(lv, "denied")

      refute has_element?(lv, "#calendar-toast", "Blocked in your browser settings.")
    end

    test "an unknown answer changes nothing", %{conn: conn} do
      {lv, user} = displayed(conn)

      answer(lv, "maybe")

      refute enabled?(user)
      refute has_element?(lv, @note)
    end
  end

  describe "switching off" do
    test "the plain toggle turns them off whatever the browser says", %{conn: conn} do
      {lv, user} = displayed(conn, preferences: [desktop_reminders_enabled: true])
      report(lv, "denied")

      lv |> element(@switch) |> render_click()

      refute enabled?(user)
      assert has_element?(lv, "#{@switch}[aria-checked='false']")
      assert_push_event(lv, "calendar:settings", %{desktop_reminders: false})
    end
  end

  describe "already on" do
    test "says nothing while the browser allows them", %{conn: conn} do
      {lv, _user} = displayed(conn, preferences: [desktop_reminders_enabled: true])

      report(lv, "granted")

      refute has_element?(lv, @note)
    end

    test "explains a browser that blocks them", %{conn: conn} do
      {lv, _user} = displayed(conn, preferences: [desktop_reminders_enabled: true])

      report(lv, "denied")

      assert has_element?(
               lv,
               @note,
               "Desktop notifications are on, but your browser is blocking them."
             )

      refute has_element?(lv, "#{@note}-grant")
    end

    test "explains a browser without notifications", %{conn: conn} do
      {lv, _user} = displayed(conn, preferences: [desktop_reminders_enabled: true])

      report(lv, "unsupported")

      assert has_element?(lv, @note, "This browser does not support notifications.")
    end

    test "offers Allow notifications when the browser was never asked, and the answer clears it",
         %{conn: conn} do
      {lv, user} = displayed(conn, preferences: [desktop_reminders_enabled: true])

      report(lv, "default")

      assert has_element?(
               lv,
               @note,
               "Desktop notifications are on, but your browser has not allowed them yet."
             )

      grant = "#{@note}-grant[phx-hook='DesktopReminderPermission']"
      assert has_element?(lv, grant, "Allow notifications")

      # The hook pushes to the component the button sits in (`pushEventTo`
      # with the element), which LiveViewTest reaches through `with_target`.
      assert has_element?(lv, "#calendar-surface #{grant}")

      lv
      |> with_target("#calendar-surface")
      |> render_hook("calendar:enable_desktop_reminders", %{"permission" => "granted"})

      assert enabled?(user)
      refute has_element?(lv, @note)
    end
  end
end
